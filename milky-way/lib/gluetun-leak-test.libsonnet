local utils = import 'milky-way/lib/utils.libsonnet';
local digests = import 'milky-way/lib/digests.libsonnet';

// VPN leak-test for the qbittorrent + gluetun pod. It continuously verifies that the torrent
// client's egress is the VPN exit, never the home/ISP IP, and exercises a REAL torrent magnet
// (ipleak.net) through the live qbittorrent. A CONFIRMED leak makes the container exit non-zero ->
// CrashLoopBackOff, which is the visible alarm (`kubectl get pods` shows it red).
//
// This pod is NOT in qbittorrent's network namespace, so its own egress is the cluster's real/home
// IP -- a perfect reference value (read from a few public echo services so we don't hard-depend on
// any single rate-limited one). It reaches qbittorrent's WebUI and gluetun's control server over the
// in-cluster Service.
//
// Leak gates:
//   A. (deterministic, no external deps) gluetun's reported public IP (= qbittorrent's only possible
//      egress, given the killswitch) must differ from the home IP. Equal => tunnel down / leaking.
//   B. (provider-agnostic, CONFIDENT-ONLY) the VPN exit IP's ASN/org (via ipinfo.io) must differ
//      from the home org. Asserted only when BOTH orgs actually resolve; if ipinfo is unreachable /
//      rate-limited (HTTP 429), the gate is SKIPPED for that cycle -- Gate A still holds -- so a 429
//      can never manufacture a false leak (the old failure mode: 429 -> false leak -> crashloop ->
//      more 429). An optional EXPECTED_VPN_ORG_REGEX brand match is off by default.
// Fail-safe: only a confirmed leak exits non-zero; tunnel-not-ready and transient lookup failures
// just warn and retry. Real-torrent step (best-effort): add the ipleak.net detection magnet via the
// WebUI API; a missing reading is advisory, gates A+B remain the backstop.
{
  new(
    name='gluetun-leak-test',
    namespace='default',
    qbittorrentService='qbittorrent.%s.svc.cluster.local' % namespace,
    webuiPort=8080,
    controlPort=8000,
    // ipleak.net torrent-address-detection magnet (their fixed detection info-hash + trackers).
    ipleakMagnet='magnet:?xt=urn:btih:9f9165d9a281a9b8e782cd5176bbcc8256fd1871&dn=ipleak-torrent-detection'
                 + '&tr=udp%3A%2F%2Ftracker.ipleak.net%3A6969%2Fannounce'
                 + '&tr=http%3A%2F%2Ftracker.ipleak.net%3A6969%2Fannounce',
    // Optional brand match against ipinfo's org string. Empty by default: VPN exits usually report
    // the hosting datacenter's ASN (NordVPN US #9860 reports Latitude.sh), not the VPN brand. The
    // real gate is exit-org != home-org. Set e.g. '(?i)nord|tefincom|m247|datacamp' to also require a match.
    expectedVpnOrgRegex='',
    checkIntervalSeconds=300,
    image=digests.python.fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,

    // Self-contained checker: stdlib only (urllib/json/re), so the bare python image needs no extra
    // packages (no curl/jq install at runtime).
    local checkPy = |||
      import json, os, re, sys, time, urllib.request, urllib.parse

      QBT = os.environ["QBT_BASE"].rstrip("/")
      GLUETUN = os.environ["GLUETUN_BASE"].rstrip("/")
      MAGNET = os.environ.get("IPLEAK_MAGNET", "")
      # Optional brand match. Off by default: VPN exit IPs commonly report the underlying datacenter
      # ASN (e.g. NordVPN servers hosted on Latitude.sh / M247 / Datacamp), not the VPN brand, so a
      # brand regex produces false "leaks". The real gate is exit-org != home-org below.
      _EXPECTED = os.environ.get("EXPECTED_VPN_ORG_REGEX", "").strip()
      ORG_RE = re.compile(_EXPECTED) if _EXPECTED else None
      INTERVAL = int(os.environ.get("CHECK_INTERVAL_SECONDS", "300"))

      def _get(url, timeout=15):
          with urllib.request.urlopen(url, timeout=timeout) as r:
              return r.read().decode().strip()

      def get_retry(url, tries=3, timeout=15):
          # Retry transient failures (notably ipinfo.io HTTP 429 rate-limits) with linear backoff.
          # Returns the body on success, or None if every attempt failed. Callers MUST treat None as
          # "unknown" -- never as data -- so a rate-limited lookup can't be mistaken for a result.
          last = None
          for i in range(tries):
              try:
                  return _get(url, timeout=timeout)
              except Exception as e:
                  last = e
                  time.sleep(2 * (i + 1))
          print("WARN: fetch failed after %d tries: %s (%s)" % (tries, url, last), flush=True)
          return None

      def post_form(url, data, timeout=15):
          body = urllib.parse.urlencode(data).encode()
          req = urllib.request.Request(url, data=body, headers={"Referer": QBT})
          with urllib.request.urlopen(req, timeout=timeout) as r:
              return r.read().decode().strip()

      def looks_like_ip(s):
          # Reject HTML/error bodies from echo services -- only accept something IP-shaped.
          return bool(s) and len(s) <= 45 and any(c.isdigit() for c in s) \
              and all(c in "0123456789abcdefABCDEF:." for c in s)

      def vpn_ip():
          # gluetun's publicip route (exposed via its config.toml); in-cluster, so not rate-limited.
          body = get_retry(GLUETUN + "/v1/publicip/ip")
          if not body:
              return None
          try:
              return json.loads(body).get("public_ip", "") or None
          except Exception:
              return None

      # This pod is outside qbittorrent's netns, so its own egress is the cluster's real/home IP.
      # Try several echo services so a single rate-limited provider can't stall the check.
      HOME_IP_URLS = ["https://icanhazip.com", "https://ifconfig.me/ip", "https://ipinfo.io/ip"]
      def home_ip():
          for u in HOME_IP_URLS:
              body = get_retry(u, tries=2)
              if not body:
                  continue
              cand = body.split()[0].strip()
              if looks_like_ip(cand):
                  return cand
              print("WARN: %s returned non-IP %r; trying next" % (u, cand[:40]), flush=True)
          return None

      def org_of(ip):
          # ipinfo.io ASN/org for an IP, or None if it couldn't be resolved (network / HTTP 429).
          # None means "unknown" and disables the org gate for this cycle -- it is NEVER compared.
          return get_retry("https://ipinfo.io/" + ip + "/org", tries=2) or None

      def leak(msg):
          # A CONFIRMED leak: exit non-zero so the Deployment CrashLoopBackOffs = visible red alarm.
          print("LEAK: " + msg, flush=True)
          sys.exit(1)

      def add_magnet():
          if not MAGNET:
              return
          try:
              # AuthSubnetWhitelist lets in-cluster callers skip login; harmless if it 403s.
              try:
                  post_form(QBT + "/api/v2/auth/login", {"username": "admin", "password": "adminadmin"})
              except Exception:
                  pass
              post_form(QBT + "/api/v2/torrents/add", {"urls": MAGNET})
              print("real-torrent: added ipleak detection magnet to qbittorrent", flush=True)
          except Exception as e:
              print("real-torrent: WARN could not add magnet: " + str(e), flush=True)

      # Cache the home org keyed by home IP: the ISP IP is stable, so we hit ipinfo's org endpoint
      # for it only when the IP changes. That (plus non-ipinfo home-IP lookups) keeps us well under
      # ipinfo's rate limit -- the 429 storm that previously caused false leaks came from re-querying
      # it every cycle and, on crashloop, every few seconds.
      home_ip_cached = None
      home_org_cached = None

      while True:
          v = vpn_ip()
          if not v:
              # No VPN exit IP => tunnel/control not ready. With gluetun's killswitch, qbittorrent has
              # NO egress at all in this state, so there is nothing to leak. Fail-safe: warn, wait,
              # retry, and never exit (a transient outage must not masquerade as a leak).
              print("WARN: VPN exit IP unavailable (tunnel not ready?); retrying", flush=True)
              time.sleep(15); continue

          h = home_ip()
          if not h:
              print("WARN: cannot determine home IP yet; retrying", flush=True)
              time.sleep(15); continue

          # Gate A (deterministic backstop, no external org dependency): VPN exit != home IP.
          if v == h:
              leak("VPN exit IP == home IP (" + v + ") -- tunnel down / leaking")

          if h != home_ip_cached:
              home_ip_cached = h
              home_org_cached = org_of(h)
          home_org = home_org_cached
          exit_org = org_of(v)

          # Gate B (provider-agnostic), CONFIDENT-ONLY: only assert when BOTH orgs actually resolved.
          # If either is None (ipinfo unavailable / 429), skip the gate this cycle -- Gate A still
          # guarantees exit != home IP, so we lose no real detection and gain no false positives.
          if exit_org and home_org:
              if exit_org == home_org:
                  leak("VPN exit org == home org (" + exit_org + ") -- traffic not leaving the home network")
              if ORG_RE is not None and not ORG_RE.search(exit_org):
                  leak("VPN exit " + v + " org=" + repr(exit_org) + " does not match EXPECTED_VPN_ORG_REGEX")
          else:
              print("WARN: org gate skipped (exit_org=%r home_org=%r) -- ipinfo unavailable; Gate A still enforced" % (exit_org, home_org), flush=True)

          add_magnet()
          print("OK: vpn_exit=%s (%s) home=%s (%s) -- no leak" % (v, exit_org, h, home_org), flush=True)
          time.sleep(INTERVAL)
    |||,

    configMap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name, namespace: namespace },
      data: { 'check.py': checkPy },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            annotations: { 'checksum/script': std.md5(checkPy) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: name,
                image: image,
                command: ['python3', '/script/check.py'],
                env: [
                  { name: 'QBT_BASE', value: 'http://%s:%d' % [qbittorrentService, webuiPort] },
                  { name: 'GLUETUN_BASE', value: 'http://%s:%d' % [qbittorrentService, controlPort] },
                  { name: 'IPLEAK_MAGNET', value: ipleakMagnet },
                  { name: 'EXPECTED_VPN_ORG_REGEX', value: expectedVpnOrgRegex },
                  { name: 'CHECK_INTERVAL_SECONDS', value: std.toString(checkIntervalSeconds) },
                  { name: 'MY_POD_IP', valueFrom: { fieldRef: { fieldPath: 'status.podIP' } } },
                ],
                volumeMounts: [
                  { name: 'script', mountPath: '/script', readOnly: true },
                ],
                resources: {
                  requests: { memory: '32Mi', cpu: '25m' },
                  limits: { memory: '128Mi', cpu: '200m' },
                },
              },
            ],
            volumes: [
              { name: 'script', configMap: { name: this.configMap.metadata.name } },
            ],
          },
        },
      },
    },
  },
}
