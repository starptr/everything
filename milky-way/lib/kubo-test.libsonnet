local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Verification service for the kubo pinned-mirror node (lib/kubo.libsonnet). It is the ONLY
// authorized RPC client: kubo's API.Authorizations grants it a bearer token scoped to the MINIMUM
// AllowedPaths needed to fully verify the node's behaviour. It continuously asserts, and a CONFIRMED
// violation exits the container non-zero -> CrashLoopBackOff, the visible red alarm (mirrors
// lib/gluetun-leak-test.libsonnet). Transient/network errors only warn + retry -- never a false alarm.
//
// What it verifies each cycle (RPC = HTTP POST to :api with `Authorization: Bearer <token>`; the
// HTTP gateway and gluetun control server are unauthenticated):
//   1. liveness          -- POST /api/v0/version (always allowed, needs no grant)
//   2. mirror            -- add a fresh local blob (pin=false) then pin/add it (the "mirror a CID" op)
//   3. pin confirmed     -- pin/ls shows it recursively pinned
//   4. serves pinned      -- gateway GET /ipfs/<cid> returns the exact bytes (NoFetch serves local)
//   5. NoFetch enforced   -- gateway GET of a computed-but-NOT-stored CID must NOT return 200 (no fetch)
//   6. policy + PF wiring -- config says Gateway.NoFetch=true, Provide.Strategy=pinned, and
//                            Addresses.Announce advertises gluetun's current forwarded port
//   7. no VPN leak        -- kubo's exit IP (gluetun control server) differs from this pod's home IP
//
// This pod is NOT in kubo's netns, so its own egress is the cluster's real/home IP -- a reference
// value for the leak gate. It reaches kubo's api/gateway/gluetun-ctrl over the in-cluster Service.
{
  new(
    rpcToken,                           // required -> Bearer token (same value as kubo's testRpcToken)
    kuboService,                        // required -> kubo's Service object (host/ports are read from it)
    name='kubo-test',
    namespace='default',
    image=images.python.fullyQualifiedImageReferencePinned,
    checkIntervalSeconds=300,
  ):: {
    local this = self,

    // Read host + ports from kubo's Service so they stay single-sourced (a renamed port fails loudly).
    local kuboHost = utils.domainOfService(kuboService),
    local kuboPorts = utils.associateObjectsByKey(kuboService.spec.ports, 'name'),
    local rpcBase = 'http://%s:%d' % [kuboHost, kuboPorts['api'].port],
    local gatewayBase = 'http://%s:%d' % [kuboHost, kuboPorts['gateway'].port],
    local ctrlBase = 'http://%s:%d' % [kuboHost, kuboPorts['gluetun-ctrl'].port],

    // Self-contained checker: stdlib only (urllib/json/os), so the bare python image needs no extra
    // packages. Reads config from env; the token from a Secret (envFrom).
    local checkPy = |||
      import json, os, sys, time, urllib.request, urllib.parse, urllib.error

      RPC = os.environ["RPC_BASE"].rstrip("/")
      GW = os.environ["GATEWAY_BASE"].rstrip("/")
      CTRL = os.environ["CTRL_BASE"].rstrip("/")
      TOKEN = os.environ["KUBO_RPC_TOKEN"]
      INTERVAL = int(os.environ.get("CHECK_INTERVAL_SECONDS", "300"))
      HOME_IP_URLS = ["https://icanhazip.com", "https://ifconfig.me/ip", "https://ipinfo.io/ip"]

      class Violation(Exception):
          # A CONFIRMED wrong behaviour -> crashloop. Distinct from transient network errors, which retry.
          pass

      def rpc(path, params=None, data=b"", content_type=None, timeout=30):
          # All kubo RPC calls are POST and carry the bearer token. Returns (status, body); HTTP errors
          # (e.g. pin/ls 500 "not pinned") are returned, not raised, so callers can inspect them.
          url = RPC + path + (("?" + urllib.parse.urlencode(params)) if params else "")
          req = urllib.request.Request(url, data=data, method="POST")
          req.add_header("Authorization", "Bearer " + TOKEN)
          if content_type:
              req.add_header("Content-Type", content_type)
          try:
              with urllib.request.urlopen(req, timeout=timeout) as r:
                  return r.status, r.read()
          except urllib.error.HTTPError as e:
              return e.code, e.read()

      def add_bytes(data, only_hash=False, pin=False):
          # Minimal multipart/form-data add. Returns the CID (last NDJSON line's Hash). only_hash=True
          # computes the CID WITHOUT storing the block (used to get a guaranteed-non-local CID).
          boundary = "----kubotestboundary7f3a"
          body = (
              ("--%s\r\n" % boundary).encode()
              + b'Content-Disposition: form-data; name="file"; filename="file"\r\n'
              + b"Content-Type: application/octet-stream\r\n\r\n"
              + data
              + ("\r\n--%s--\r\n" % boundary).encode()
          )
          params = {"pin": "true" if pin else "false", "only-hash": "true" if only_hash else "false"}
          st, resp = rpc("/api/v0/add", params, data=body,
                         content_type="multipart/form-data; boundary=" + boundary)
          if st != 200:
              raise Exception("add failed (status %s): %s" % (st, resp[:200]))
          lines = [l for l in resp.decode().splitlines() if l.strip()]
          return json.loads(lines[-1])["Hash"]

      def cfg(key):
          st, body = rpc("/api/v0/config", {"arg": key})
          if st != 200:
              raise Exception("config read %s failed (status %s)" % (key, st))
          return json.loads(body).get("Value")

      def gw_get(path, timeout=20, allow_fail=False):
          # GET the unauthenticated gateway. Returns (status, body); on a network error returns
          # (None, b"") when allow_fail (used for the NoFetch check, where a non-200/timeout = refused).
          try:
              with urllib.request.urlopen(GW + path, timeout=timeout) as r:
                  return r.status, r.read()
          except urllib.error.HTTPError as e:
              return e.code, e.read()
          except Exception:
              if allow_fail:
                  return None, b""
              raise

      def ctrl_json(path):
          try:
              with urllib.request.urlopen(CTRL + path, timeout=10) as r:
                  return json.loads(r.read())
          except Exception:
              return None

      def looks_like_ip(s):
          return bool(s) and len(s) <= 45 and any(c.isdigit() for c in s) \
              and all(c in "0123456789abcdefABCDEF:." for c in s)

      def home_ip():
          # This pod is OUTSIDE kubo's netns, so its egress is the cluster's real/home IP.
          for u in HOME_IP_URLS:
              try:
                  with urllib.request.urlopen(u, timeout=10) as r:
                      cand = r.read().decode().split()[0].strip()
                  if looks_like_ip(cand):
                      return cand
              except Exception:
                  continue
          return None

      def cycle():
          # 1. liveness (version is always allowed -> if this 401s, the token/grant is wrong).
          st, _ = rpc("/api/v0/version")
          if st == 401 or st == 403:
              raise Violation("RPC auth rejected (status %s) -- token/AllowedPaths wrong" % st)
          if st != 200:
              raise Exception("RPC not ready (version status %s)" % st)

          # 2. mirror: add a fresh local blob (unpinned) then pin/add it.
          payload = ("kubo-mirror-test %f %s " % (time.time(), os.environ.get("HOSTNAME", ""))).encode() + os.urandom(16)
          cid = add_bytes(payload, only_hash=False, pin=False)
          st, body = rpc("/api/v0/pin/add", {"arg": cid})
          if st != 200:
              raise Violation("pin/add failed for %s (status %s): %s" % (cid, st, body[:200]))

          # 3. pin confirmed recursive.
          st, body = rpc("/api/v0/pin/ls", {"arg": cid, "type": "recursive"})
          if st != 200:
              raise Violation("pin/ls did not confirm %s pinned (status %s): %s" % (cid, st, body[:200]))
          keys = json.loads(body).get("Keys", {})
          if keys.get(cid, {}).get("Type") != "recursive":
              raise Violation("pin/ls missing recursive pin for %s: %s" % (cid, body[:200]))

          # 4. serves the pinned content via the gateway (NoFetch serves local).
          gst, gbody = gw_get("/ipfs/" + cid, timeout=20)
          if gst != 200 or gbody != payload:
              raise Violation("gateway did not serve pinned %s (status %s, %d bytes)" % (cid, gst, len(gbody)))

          # 5. NoFetch: a computed-but-NOT-stored CID must NOT be served (the gateway must not fetch).
          cid2 = add_bytes(os.urandom(32), only_hash=True, pin=False)
          nst, _ = gw_get("/ipfs/" + cid2, timeout=8, allow_fail=True)
          if nst == 200:
              raise Violation("NoFetch VIOLATED: gateway served non-local CID %s (it fetched from the network)" % cid2)

          # 6. policy + port-forward wiring.
          nofetch = cfg("Gateway.NoFetch")
          if nofetch is not True:
              raise Violation("Gateway.NoFetch is not true: %r" % nofetch)
          strategy = cfg("Provide.Strategy")
          if strategy != "pinned":
              raise Violation("Provide.Strategy is not 'pinned': %r" % strategy)
          announce = cfg("Addresses.Announce") or []
          pf = ctrl_json("/v1/portforward")
          fwd = pf.get("port") if isinstance(pf, dict) else None
          if fwd:
              if not any(("/tcp/%d" % fwd) in a for a in announce):
                  raise Violation("Addresses.Announce %r does not advertise forwarded port %d" % (announce, fwd))
          else:
              print("WARN: forwarded port unavailable from gluetun-ctrl; announce check skipped", flush=True)

          # 7. VPN-leak gate: kubo's exit IP must differ from this pod's home IP.
          pip = ctrl_json("/v1/publicip/ip")
          exit_ip = (pip.get("public_ip") or None) if isinstance(pip, dict) else None
          home = home_ip()
          if exit_ip and home:
              if exit_ip == home:
                  raise Violation("kubo egress == home IP (%s): tunnel down / leaking" % exit_ip)
          else:
              print("WARN: leak gate skipped (exit=%r home=%r)" % (exit_ip, home), flush=True)

          print("OK: cid=%s served; non-local refused; NoFetch=%r Provide.Strategy=%r; announce=%s; vpn_exit=%s home=%s"
                % (cid, nofetch, strategy, announce, exit_ip, home), flush=True)

      while True:
          try:
              cycle()
              time.sleep(INTERVAL)
          except Violation as v:
              print("FAIL: " + str(v), flush=True)
              sys.exit(1)
          except Exception as e:
              print("WARN: transient error, retrying: %s" % e, flush=True)
              time.sleep(15)
    |||,

    // Token in its own Secret (not plain env) -- consumed via envFrom.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-token', namespace: namespace },
      type: 'Opaque',
      stringData: { KUBO_RPC_TOKEN: rpcToken },
    },

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
            // Roll the pod when the script OR the token changes (neither is in the pod template).
            annotations: { 'checksum/config': std.md5(checkPy + rpcToken) },
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
                  { name: 'RPC_BASE', value: rpcBase },
                  { name: 'GATEWAY_BASE', value: gatewayBase },
                  { name: 'CTRL_BASE', value: ctrlBase },
                  { name: 'CHECK_INTERVAL_SECONDS', value: std.toString(checkIntervalSeconds) },
                ],
                envFrom: [{ secretRef: { name: this.secret.metadata.name } }],  // KUBO_RPC_TOKEN
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
