local utils = import 'milky-way/lib/utils.libsonnet';

// VPN leak-test for the qbittorrent + gluetun pod. It continuously verifies that the torrent
// client's egress is the VPN exit, never the home/ISP IP, and exercises a REAL torrent magnet
// (ipleak.net) through the live qbittorrent. A confirmed leak makes the container exit non-zero ->
// CrashLoopBackOff, which is the visible alarm (`kubectl get pods` shows it red).
//
// This pod is NOT in qbittorrent's network namespace, so:
//   * its own egress (ipinfo.io) is the cluster's real/home IP -> a perfect reference value;
//   * it reaches qbittorrent's WebUI and gluetun's control server over the in-cluster Service.
//
// Deterministic gates (hard fail):
//   A. gluetun's reported public IP (= qbittorrent's only possible egress, given the killswitch)
//      must differ from the home IP. Equal => tunnel down / leaking.
//   B. that IP's ASN/org must look like NordVPN. Mismatch => tunnel up but not the expected VPN.
// Real-torrent step (best-effort, per user choice): add the ipleak.net detection magnet to
// qbittorrent via the WebUI API. ipleak's result endpoint is undocumented/rate-limited, so a
// missing reading is advisory (logged), while gates A+B remain the deterministic backstop.
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
    image='python:3.12-alpine@sha256:2d07747661646f3d904e995a232fb19e461afde69e67e6f7f3b52c7b968a88b3',
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

      def get(url, timeout=15):
          with urllib.request.urlopen(url, timeout=timeout) as r:
              return r.read().decode().strip()

      def post_form(url, data, timeout=15):
          body = urllib.parse.urlencode(data).encode()
          req = urllib.request.Request(url, data=body, headers={"Referer": QBT})
          with urllib.request.urlopen(req, timeout=timeout) as r:
              return r.read().decode().strip()

      def vpn_ip():
          # publicip route is made public via gluetun's config.toml.
          return json.loads(get(GLUETUN + "/v1/publicip/ip")).get("public_ip", "")

      def home_ip():
          # This pod is outside qbittorrent's netns, so this is the cluster's real egress IP.
          return get("https://ipinfo.io/ip")

      def org_of(ip):
          try:
              return get("https://ipinfo.io/" + ip + "/org")
          except Exception as e:
              return "?(" + str(e) + ")"

      def leak(msg):
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

      while True:
          try:
              h = home_ip()
              home_org = org_of(h)
          except Exception as e:
              print("WARN: cannot determine home IP yet: " + str(e), flush=True)
              time.sleep(15); continue
          try:
              v = vpn_ip()
          except Exception as e:
              # No VPN IP => tunnel/control not ready. With the killswitch, qbittorrent has no egress
              # at all in this state, so there is no leak to report. Wait and retry (fail-safe).
              print("WARN: cannot read VPN exit IP (tunnel not ready?): " + str(e), flush=True)
              time.sleep(15); continue

          if not v:
              print("WARN: empty VPN exit IP; retrying", flush=True)
              time.sleep(15); continue
          # Gate A: VPN exit must not be the home IP.
          if v == h:
              leak("VPN exit IP == home IP (" + v + ") -- tunnel down / leaking")
          # Gate B: VPN exit must NOT be on the home ISP/org (provider-agnostic leak check).
          exit_org = org_of(v)
          if exit_org and home_org and exit_org == home_org:
              leak("VPN exit org == home org (" + exit_org + ") -- traffic not leaving the home network")
          # Optional gate: only if EXPECTED_VPN_ORG_REGEX was explicitly set.
          if ORG_RE is not None and not ORG_RE.search(exit_org):
              leak("VPN exit " + v + " org=" + repr(exit_org) + " does not match EXPECTED_VPN_ORG_REGEX")

          add_magnet()
          print("OK: vpn_exit=" + v + " (" + exit_org + ") home=" + h + " (" + home_org + ") -- no leak", flush=True)
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
