local utils = import 'milky-way/lib/utils.libsonnet';
local gluetun = import 'milky-way/lib/gluetun.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// kubo (go-ipfs): a pinned-MIRROR IPFS node. It only ever serves and announces ALLOWLISTED
// (pinned) content -- two config keys enforce that intent:
//   * Gateway.NoFetch = true   -- the HTTP gateway serves ONLY blocks already in the local repo;
//                                 it never reaches out to the network to fetch a CID it lacks.
//   * Provide.Strategy = pinned -- the node announces ONLY recursively-pinned roots (+ their child
//                                 blocks) to the DHT, so it advertises exactly what it mirrors.
//
// IP hiding is done at the NETWORK layer: kubo runs behind an embedded gluetun sidecar (the exact
// qbittorrent/thelounge pattern, see lib/gluetun.libsonnet) so every swarm dial / DHT write leaves
// from the ProtonVPN exit IP, never the home IP. The killswitch does NOT block in-cluster ClusterIP
// access -- gluetun's FIREWALL_INPUT_PORTS (gateway + api + ctrl) + FIREWALL_OUTBOUND_SUBNETS (the
// pod/service CIDRs) + conntrack keep those ports reachable, so the in-cluster verifier (and any
// future gateway ingress) can reach them. This needs its OWN ProtonVPN WireGuard session/key
// (concurrent tunnels on one key flap), wired from a sops .conf in main.jsonnet like qbittorrent.
//
// Inbound reachability (be a dialable provider): gluetun requests a ProtonVPN NAT-PMP forwarded
// port and auto-opens it on the VPN interface. The wrinkle vs qbittorrent: qbittorrent has a live
// WebUI API to set its listen port on each (re)assignment, but kubo reads Addresses.Swarm /
// Addresses.Announce ONLY at daemon start and has no runtime RPC to mutate them. So the container
// runs a WRAPPER that waits for gluetun's forwarded port, sets kubo to LISTEN on it and ANNOUNCE
// <vpn-exit>:port, then execs the daemon; a livenessProbe restarts the container if the forwarded
// port later changes (rare -- only on a VPN reconnect; the port is stable per-connection).
//
// Config delivery is NOT the seed-a-config.json pattern: `ipfs init` generates the node Identity
// (PeerID + key), so a static config.json seed would omit it and the daemon would refuse to start.
// Instead the wrapper lets init create the repo, then re-asserts our keys via `ipfs config` every
// boot (declarative for the keys we manage; kubo owns identity/datastore/pinset on the PVC).
//
// RPC API is locked down with API.Authorizations (admin RPC must NEVER be open): there are two bearer
// grants -- the test service (scoped to the minimum AllowedPaths needed to verify the node, see
// testAllowedPaths) and the WebUI (full /api/v0, see webuiAllowedPaths). Storage: the repo
// (identity/datastore/pinset) is on iSCSI (RWO) -- the datastore does file locking, unsafe over NFS
// (same rationale as jellyfin's SQLite) -- so an RWO PVC means the old pod must release it before a new
// one mounts, hence strategy: Recreate.
//
// WebUI: kubo bundles a WebUI served at /webui on the API port (NOT gated by API.Authorizations; only
// /api/v0 is). We expose it tailnet-only via an nginx SIDECAR + a Tailscale L7 ingress -- the sidecar
// proxies the ingress to kubo over loopback (127.0.0.1, shared pod netns -- NOT through the VPN tunnel;
// its inbound port is opened in gluetun's killswitch like the others) and INJECTS the webui bearer token
// so the browser never holds it (and rewrites Origin to kubo's safelisted loopback, since kubo 403s
// browser-UA requests whose Origin isn't safelisted -- see the sidecar config). The admin RPC itself
// stays ClusterIP-only -- only the sidecar's webui port is exposed. Because Gateway.NoFetch=true, /webui
// only renders if the bundled WebUI CID is local, so the wrapper pins it (webuiCid) on boot.
//
// PUBLIC GATEWAY: the HTTP gateway is ALSO exposed to the public internet as a SUBDOMAIN gateway at
// gatewayBaseDomain (e.g. ipfs.andref.app) + its wildcard, via a cert-manager wildcard cert (Let's
// Encrypt DNS-01) that Traefik serves in front of the gateway ClusterIP port. That hop is in-cluster
// (Traefik -> Service -> gateway, NOT the VPN; the gateway port is already in the killswitch's
// FIREWALL_INPUT_PORTS, same path as the verifier). Gateway.PublicGateways UseSubdomains gives each
// content root its own browser origin at <cid>.ipfs.<gatewayPublicGatewayKey>. NoFetch still applies,
// so the public gateway serves ONLY pinned content (a non-pinned CID -> 404, never a swarm fetch).
// NOTE the asymmetry: this exposes the home IP for GATEWAY HTTP only (its DNS CNAMEs point at the
// home-IP DDNS record), while the swarm/DHT still leaves only from the VPN exit -- so the home IP
// stays off the IPFS swarm.
{
  // The minimum RPC AllowedPaths the verifier needs (single source of truth -- baked into
  // API.Authorizations by the wrapper, and the intended contract for kubo-test). AllowedPaths are
  // path PREFIXES; /api/v0/version is always allowed (used for liveness, so it needs no grant).
  //   * /api/v0/add      -- create local test content (pin=false) AND compute a non-local CID (only-hash)
  //   * /api/v0/pin/add  -- THE "mirror an allowlisted CID" operation under test
  //   * /api/v0/pin/ls   -- confirm the CID landed in the recursive pinset
  //   * /api/v0/config   -- read back Gateway.NoFetch / Provide.Strategy / Addresses.Announce
  // Serving + NoFetch are verified through the UNAUTHENTICATED gateway (the only surface where
  // NoFetch lives), so no /api/v0/cat|get|block grant is needed. /api/v0/config is the one
  // unavoidable broad-ish grant (kubo has no read-only single-key config path); the test only reads.
  defaultTestAllowedPaths:: [
    '/api/v0/add',
    '/api/v0/pin/add',
    '/api/v0/pin/ls',
    '/api/v0/config',
  ],

  new(
    testRpcToken,                       // required -> API.Authorizations bearer secret (shared with the test)
    wireguardPrivateKey,                // required -> gluetun (ProtonVPN/WireGuard), its OWN session/key
    vpnProvider,                        // required: must support NAT-PMP port forwarding, e.g. 'protonvpn'
    serverCountries,                    // required: SERVER_COUNTRIES, e.g. 'United States'
    webuiRpcToken,                      // required -> API.Authorizations 'webui' bearer secret, injected by the sidecar
    tailscaleHostname,                  // required, NO default: tailnet MagicDNS name (must be unique tailnet-wide)
    gatewayBaseDomain,                  // required, NO default: public gateway hostname; cert + Ingress SANs are this + '*.'+this (e.g. 'ipfs.andref.app')
    gatewayPublicGatewayKey,            // required, NO default: Gateway.PublicGateways map key; kubo serves subdomain content at <cid>.ipfs.<key>, so 'andref.app' => <cid>.ipfs.andref.app
    gatewayIssuerName,                  // required, NO default: cert-manager ClusterIssuer the wildcard gateway cert is issued from
    name='kubo',
    namespace='default',
    image=images.kubo.fullyQualifiedImageReferencePinned,
    apiPort=5001,                       // kubo RPC API (locked down by API.Authorizations)
    gatewayPort=8080,                   // kubo HTTP gateway (NoFetch: serves only local/pinned content)
    controlPort=8000,                   // gluetun control server (publicip + portforward routes)
    storageClassName='my-custom-zfs-generic-iscsi',   // RWO; the datastore must not be on NFS
    storageSize='10Gi',
    ipfsPath='/data/ipfs',
    testAuthName='test',                // API.Authorizations entry name for the verifier
    testAllowedPaths=self.defaultTestAllowedPaths,
    webuiAuthName='webui',              // API.Authorizations entry name for the WebUI
    webuiAllowedPaths=['/api/v0'],      // full RPC: everything the WebUI needs for normal operation
    webuiProxyPort=8081,                // nginx sidecar listen port (fronts /webui + RPC, injects the token)
    webuiCid='bafybeihxglpcfyarpm7apn7xpezbuoqgk3l5chyk7w4gvrjwk45rqohlmm',  // bundled WebUI (ipfs-webui v4.12.0) that kubo v0.42.0's /webui redirects to; pinned so NoFetch can serve it. Update on kubo bumps.
    nginxImage=images.nginx.fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,

    // The wildcard gateway cert (*.<gatewayBaseDomain>) must cover the subdomain-gateway content,
    // which kubo serves at <cid>.ipfs.<gatewayPublicGatewayKey>. That holds iff gatewayBaseDomain ==
    // 'ipfs.' + gatewayPublicGatewayKey -- assert it so a mismatch fails at eval, not later as a
    // browser cert error.
    assert gatewayBaseDomain == 'ipfs.' + gatewayPublicGatewayKey :
      'kubo: gatewayBaseDomain (%s) must equal "ipfs." + gatewayPublicGatewayKey (%s)'
      % [gatewayBaseDomain, gatewayPublicGatewayKey],

    // Cluster CIDRs (k3s defaults; verified on methanol). Kept reachable through the killswitch so
    // the in-cluster verifier + kubelet probes can reach the gateway/API/ctrl and get return traffic.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',

    // Compact JSON array of the grant, injected into the wrapper as an env var so API.Authorizations
    // is single-sourced from this jsonnet (no newlines, so it embeds cleanly into the shell --json arg).
    local allowedPathsJson = std.manifestJsonEx(testAllowedPaths, '', ''),
    local webuiAllowedPathsJson = std.manifestJsonEx(webuiAllowedPaths, '', ''),

    // The nginx WebUI-proxy sidecar config. It carries the bearer token, so it lives in a Secret (below),
    // not a ConfigMap. Proxies everything to kubo over loopback (NOT the VPN), and injects the token so the
    // browser never holds it. kubo enforces Origin-based RPC security for BROWSER requests (it flags a
    // browser by a Mozilla User-Agent) and 403s unless the Origin is safelisted -- and it ALWAYS safelists
    // its own loopback origin. So set Origin to http://127.0.0.1:<apiPort> (do NOT strip it: a browser
    // request with no Origin still 403s) and drop Referer. The browser's real calls are same-origin, so it
    // ignores the resulting Access-Control-Allow-Origin -- no kubo API.HTTPHeaders/CORS config is needed.
    // Streaming/large-upload friendly.
    //
    // First-load shim (the `~ ^/(webui/?)?$` location): the bundled WebUI has no same-origin / ?api=
    // default, so on a fresh browser it tries localhost:5001 (the user's OWN machine) and shows "Could
    // not connect". So serve a tiny page at / and /webui that pre-seeds the WebUI's saved RPC address
    // (localStorage 'ipfsApi', read back through asAPIOptions -> a plain origin URL is accepted) to THIS
    // origin, then sends the browser to the app at /ipfs/<webuiCid>/. localStorage is per-origin, so the
    // app reads it and calls /api/v0 here, where the proxy injects the token. Everything else (the app's
    // own /ipfs/<cid>/ assets + /api/v0) falls through to the proxy below.
    local nginxConf = (|||
      server {
        listen %(webuiProxyPort)s;
        location ~ ^/(webui/?)?$ {
          default_type text/html;
          return 200 "<!doctype html><meta charset='utf-8'><title>IPFS WebUI</title><script>try{localStorage.setItem('ipfsApi',JSON.stringify(location.origin))}catch(e){}location.replace('/ipfs/%(webuiCid)s/')</script>";
        }
        location / {
          proxy_pass http://127.0.0.1:%(apiPort)s;
          proxy_set_header Authorization "Bearer %(token)s";
          proxy_set_header Origin "http://127.0.0.1:%(apiPort)s";
          proxy_set_header Referer "";
          proxy_http_version 1.1;
          proxy_buffering off;
          proxy_request_buffering off;
          client_max_body_size 0;
          proxy_read_timeout 1h;
        }
      }
    |||) % { webuiProxyPort: webuiProxyPort, apiPort: apiPort, token: webuiRpcToken, webuiCid: webuiCid },

    // The kubo container's command. Static policy is re-asserted every boot; the dynamic swarm
    // listen/announce addresses are wired from gluetun's forwarded port (see header for why a wrapper
    // + restart, not a runtime poke). $TEST_AUTH_NAME / $KUBO_TEST_RPC_TOKEN / $ALLOWED_PATHS_JSON
    // come from the container env (token via the Secret) so the grant + token stay out of the ConfigMap.
    local wrapperScript = (|||
      #!/bin/sh
      set -eu
      export IPFS_PATH=%(ipfsPath)s

      # First boot: `ipfs init` generates the node Identity (PeerID + key). The `server` profile
      # disables mDNS/local-network announcing (a datacenter/VPN node), complementing the VPN-only
      # announce below. We never seed a static config.json -- that would omit the identity.
      [ -f "$IPFS_PATH/config" ] || ipfs init --profile server

      # --- static policy (re-asserted every boot; kubo owns identity/datastore/pinset on the PVC) ---
      ipfs config Addresses.API     /ip4/0.0.0.0/tcp/%(apiPort)s        # bind beyond loopback so the Service reaches it
      ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/%(gatewayPort)s
      ipfs config --bool Gateway.NoFetch true                          # serve ONLY locally-present (pinned) content
      ipfs config Provide.Strategy pinned                              # announce ONLY pinned roots to the DHT
      # Subdomain gateway: serve each content root from its OWN browser origin at <cid>.ipfs.<key>
      # (origin isolation). NoFetch still applies, so only locally-pinned CIDs resolve. The key is the
      # BARE zone (gatewayPublicGatewayKey), NOT the public hostname, because kubo serves at
      # <cid>.ipfs.<key>; key=andref.app => <cid>.ipfs.andref.app, matching the *.ipfs.andref.app cert.
      ipfs config --json Gateway.PublicGateways \
        '{"%(gatewayPublicGatewayKey)s":{"UseSubdomains":true,"Paths":["/ipfs"]}}'
      ipfs config --bool Swarm.DisableNatPortMap true                  # gluetun owns NAT-PMP (VPN side), not kubo
      # Bound the swarm so gluetun (which tracks every connection in its firewall/netns) doesn't OOM:
      # a pinned mirror that serves/announces pinned content needs no large peer set.
      ipfs config --json Swarm.ConnMgr '{"Type":"basic","LowWater":30,"HighWater":100,"GracePeriod":"20s"}'
      # Two bearer grants in ONE call (the key is overwritten wholesale): the scoped test verifier and the
      # full-/api/v0 WebUI (consumed by the nginx sidecar, which injects this token on the browser's behalf).
      ipfs config --json API.Authorizations \
        "{\"$TEST_AUTH_NAME\":{\"AuthSecret\":\"bearer:$KUBO_TEST_RPC_TOKEN\",\"AllowedPaths\":$ALLOWED_PATHS_JSON},\"$WEBUI_AUTH_NAME\":{\"AuthSecret\":\"bearer:$KUBO_WEBUI_RPC_TOKEN\",\"AllowedPaths\":$WEBUI_ALLOWED_PATHS_JSON}}"

      # --- dynamic: wait for gluetun's NAT-PMP forwarded port, then listen on + announce <vpn-exit>:PORT ---
      # gluetun's up-command writes the port to /pf/port. Wait for a non-empty, non-zero value: gluetun
      # reports 0 while no port is forwarded (tunnel/PF not up yet), and announcing port 0 is useless.
      echo "waiting for gluetun port-forward (/pf/port)..."
      PORT=""
      while [ -z "$PORT" ] || [ "$PORT" = "0" ]; do
        sleep 2
        PORT="$(cat /pf/port 2>/dev/null || true)"
      done
      EXIT_IP=""
      while [ -z "$EXIT_IP" ]; do
        EXIT_IP="$(wget -q -O - http://127.0.0.1:%(controlPort)s/v1/publicip/ip 2>/dev/null \
                   | sed -n 's/.*"public_ip":"\([^"]*\)".*/\1/p')"
        [ -n "$EXIT_IP" ] || { echo "waiting for gluetun publicip..."; sleep 2; }
      done
      echo "forwarded port=$PORT vpn_exit=$EXIT_IP"
      ipfs config --json Addresses.Swarm \
        "[\"/ip4/0.0.0.0/tcp/$PORT\",\"/ip4/0.0.0.0/udp/$PORT/quic-v1\"]"
      # Announce ONLY the reachable VPN address (override, not append) so we never advertise the
      # unreachable in-cluster pod IP to the public DHT.
      ipfs config --json Addresses.Announce \
        "[\"/ip4/$EXIT_IP/tcp/$PORT\",\"/ip4/$EXIT_IP/udp/$PORT/quic-v1\"]"
      echo "$PORT" > /tmp/announced-port

      # Pin the bundled WebUI so kubo's /webui works on this NoFetch node (which serves /webui only if the
      # content is already local). Best-effort + backgrounded so it never blocks or crashes the daemon: it
      # waits for the RPC to accept the webui token, then POSTs pin/add for the WebUI CID. busybox wget
      # supports --header/--post-data; this process survives the `exec` below and keeps polling.
      pin_webui() {
        n=0
        while [ "$n" -lt 60 ]; do
          if wget -q -O /dev/null \
               --header="Authorization: Bearer $KUBO_WEBUI_RPC_TOKEN" --post-data='' \
               "http://127.0.0.1:%(apiPort)s/api/v0/pin/add?arg=$WEBUI_CID&progress=false"; then
            echo "pinned webui $WEBUI_CID"
            return 0
          fi
          n=$((n + 1))
          sleep 5
        done
        echo "WARN: could not pin webui $WEBUI_CID; kubo /webui will error until it is pinned"
      }
      pin_webui &

      exec ipfs daemon
    |||) % { ipfsPath: ipfsPath, apiPort: apiPort, gatewayPort: gatewayPort, controlPort: controlPort, gatewayPublicGatewayKey: gatewayPublicGatewayKey },

    // Liveness: restart kubo if gluetun's forwarded port changed (kubo can't re-announce without a
    // restart). Conservative -- only restart on a CONFIRMED change; if either value is unavailable
    // (still waiting for PF, or the control server is briefly unreachable), stay up. Daemon crashes
    // are handled separately: the wrapper `exec`s the daemon (it becomes PID 1), so an exit restarts
    // the container on its own.
    local livenessScript = (|||
      set -u
      announced="$(cat /tmp/announced-port 2>/dev/null || true)"
      [ -n "$announced" ] || exit 0
      live="$(wget -q -O - http://127.0.0.1:%(controlPort)s/v1/portforward 2>/dev/null \
              | sed -n 's/.*"port":\([0-9]*\).*/\1/p')"
      # '' / non-numeric / 0 all mean "PF currently unavailable" (tunnel down or between leases) --
      # stay up rather than restart, so a transient blip doesn't churn the daemon. Only a CONFIRMED
      # change to a different non-zero port restarts us to re-announce.
      case "$live" in '' | 0 | *[!0-9]*) exit 0 ;; esac
      [ "$announced" = "$live" ] || { echo "forwarded port changed: $announced -> $live; restarting to re-announce"; exit 1; }
      exit 0
    |||) % { controlPort: controlPort },

    // The VPN sidecar fragments, embedded into this pod below. firewallInputPorts opens the gateway +
    // API + control + webui-proxy ports through the killswitch (cluster side); the forwarded SWARM port is auto-
    // opened on the VPN interface by gluetun (not here). The up-command publishes the forwarded port
    // to the shared /pf volume for the wrapper; publicControlRoutes exposes /v1/portforward so the
    // wrapper (and the verifier) can read it / the VPN exit IP.
    vpn:: gluetun.new(
      wireguardPrivateKey=wireguardPrivateKey,
      name=name + '-gluetun',
      namespace=namespace,
      vpnProvider=vpnProvider,
      vpnType='wireguard',
      serverCountries=serverCountries,
      controlPort=controlPort,
      firewallOutboundSubnets='%s,%s' % [podCidr, svcCidr],
      firewallInputPorts=[gatewayPort, apiPort, controlPort, webuiProxyPort],
      portForwarding=true,
      portForwardingUpCommand="/bin/sh -c 'echo {{PORT}} > /pf/port'",
      publicControlRoutes=['GET /v1/publicip/ip', 'GET /v1/portforward'],
    ),

    // Re-emit the gluetun-owned manifests so Tanka applies them.
    vpnSecret: this.vpn.secret,
    vpnControlConfig: this.vpn.configMap,

    // RPC bearer token, kept in a Secret (not the ConfigMap): the wrapper reads it from env and bakes
    // it into API.Authorizations at boot.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-rpc-auth', namespace: namespace },
      type: 'Opaque',
      stringData: { KUBO_TEST_RPC_TOKEN: testRpcToken, KUBO_WEBUI_RPC_TOKEN: webuiRpcToken },
    },

    // nginx WebUI-proxy config (carries the bearer token -> Secret, not ConfigMap), mounted over the
    // stock /etc/nginx/conf.d so it's the only server block.
    nginxConfigSecret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-webui-proxy', namespace: namespace },
      type: 'Opaque',
      stringData: { 'default.conf': nginxConf },
    },

    configMapWrapper: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-wrapper', namespace: namespace },
      data: { 'run.sh': wrapperScript },
    },

    configPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-repo', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: storageClassName,
        resources: { requests: { storage: storageSize } },
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // RWO repo PVC: old pod must release before new mounts
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // The wrapper (ConfigMap mount) and token (Secret via envFrom) don't roll the Deployment
            // on their own; hashing them into the template makes a change to either roll the pod.
            annotations: { 'checksum/config': std.md5(wrapperScript + testRpcToken + webuiRpcToken + nginxConf + webuiCid) },
          },
          spec: {
            // kubo runs as uid `ipfs`; fsGroup makes the iSCSI repo volume group-writable so it can
            // write the datastore/pinset regardless of the image's exact uid.
            securityContext: { fsGroup: 1000 },
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // DNS: drop the cluster search domains (same musl/ndots fix as qbittorrent/thelounge).
            // kubo's busybox image is musl; it resolves PUBLIC IPFS bootstrap/peer names (via
            // gluetun's 127.0.0.1 resolver through the tunnel) and NEVER an in-cluster name (the
            // verifier dials INTO kubo; the wrapper reads gluetun over literal 127.0.0.1), so the
            // cluster search domains are dead weight and break public DNS. dnsPolicy:None drops them;
            // it requires a nameserver, so we declare gluetun's embedded resolver (shared netns).
            dnsPolicy: 'None',
            dnsConfig: {
              nameservers: ['127.0.0.1'],
              searches: [],
            },
            // gluetun FIRST (tunnel + killswitch + PF up before kubo egresses/announces), then kubo,
            // which shares gluetun's netns automatically (same pod). gluetun also gets the shared /pf
            // mount so its up-command can publish the forwarded port to the wrapper.
            containers: [
              // gluetun + three k8s tweaks layered onto the builder's container:
              //   * /pf mount so its port-forward up-command can hand the forwarded port to the wrapper.
              //   * lifecycle.postStart deletes any leftover WireGuard IP rules (table 51820) on
              //     (re)start. In k8s the pod netns survives a CONTAINER restart, so after a gluetun
              //     restart (e.g. an OOMKill) the old rules remain and gluetun dies with "adding IPv6
              //     rule ... file exists" and never reconnects. Deleting them first makes it always come
              //     up. Recreate strategy (set above) + this hook is the gluetun-wiki k8s fix.
              //   * more memory + CPU: kubo's DHT/swarm pushes far more connections/packets through
              //     gluetun than a torrent client, so gluetun's default 256Mi/500m OOMKills and
              //     CPU-throttles (a throttled gluetun fails its health check -> reconnect churn).
              //     Give it headroom, paired with the Swarm.ConnMgr cap in the wrapper that bounds the
              //     churn at the source.
              this.vpn.container + {
                volumeMounts+: [{ name: 'pf', mountPath: '/pf' }],
                lifecycle: {
                  postStart: { exec: { command: ['/bin/sh', '-c', '(ip rule del table 51820; ip -6 rule del table 51820) || true'] } },
                },
                resources+: {
                  requests+: { memory: '128Mi' },
                  limits+: { memory: '768Mi', cpu: '1' },
                },
              },
              {
                name: name,
                image: image,
                command: ['sh', '/wrapper/run.sh'],
                env: [
                  { name: 'IPFS_PATH', value: ipfsPath },
                  { name: 'TEST_AUTH_NAME', value: testAuthName },
                  { name: 'ALLOWED_PATHS_JSON', value: allowedPathsJson },
                  { name: 'WEBUI_AUTH_NAME', value: webuiAuthName },
                  { name: 'WEBUI_ALLOWED_PATHS_JSON', value: webuiAllowedPathsJson },
                  { name: 'WEBUI_CID', value: webuiCid },
                ],
                envFrom: [{ secretRef: { name: this.secret.metadata.name } }],  // KUBO_TEST_RPC_TOKEN + KUBO_WEBUI_RPC_TOKEN
                ports: [
                  { name: 'api', containerPort: apiPort },
                  { name: 'gateway', containerPort: gatewayPort },
                ],
                // The wrapper waits for gluetun's tunnel + PF before starting the daemon, so startup
                // is slow and variable; gate readiness/liveness behind a generous startupProbe on the
                // (auth-gated, so TCP-only) API port.
                startupProbe: {
                  tcpSocket: { port: 'api' },
                  periodSeconds: 10,
                  failureThreshold: 60,   // up to ~10 min for VPN + PF + daemon
                },
                readinessProbe: {
                  tcpSocket: { port: 'api' },
                  periodSeconds: 15,
                },
                livenessProbe: {
                  exec: { command: ['sh', '-c', livenessScript] },
                  periodSeconds: 60,
                  timeoutSeconds: 10,
                  failureThreshold: 2,
                },
                volumeMounts: [
                  { name: 'repo', mountPath: ipfsPath },
                  { name: 'wrapper', mountPath: '/wrapper', readOnly: true },
                  { name: 'pf', mountPath: '/pf' },
                ],
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '2Gi', cpu: '2' },
                },
              },
              // WebUI-proxy sidecar: fronts kubo's /webui + RPC for the tailnet ingress, injecting the
              // webui bearer token so the browser never holds it. Reaches kubo over loopback (shared
              // netns), so its inbound port is opened in gluetun's firewallInputPorts above.
              {
                name: name + '-webui-proxy',
                image: nginxImage,
                ports: [{ name: 'webui', containerPort: webuiProxyPort }],
                readinessProbe: {
                  tcpSocket: { port: 'webui' },
                  periodSeconds: 15,
                },
                volumeMounts: [
                  { name: 'webui-proxy-config', mountPath: '/etc/nginx/conf.d', readOnly: true },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '10m' },
                  limits: { memory: '64Mi', cpu: '200m' },
                },
              },
            ],
            volumes: this.vpn.volumes + [
              { name: 'repo', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'wrapper', configMap: { name: this.configMapWrapper.metadata.name } },
              { name: 'pf', emptyDir: {} },
              { name: 'webui-proxy-config', secret: { secretName: this.nginxConfigSecret.metadata.name } },
            ],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: name, namespace: namespace },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [
          {
            // kubo is the 2nd container (gluetun is [0]); its ports are [api, gateway].
            name: 'api',
            port: apiPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[1].ports[0].name, 'api'),
          },
          {
            name: 'gateway',
            port: gatewayPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[1].ports[1].name, 'gateway'),
          },
          {
            // gluetun's control port, exposed so the verifier can read the VPN exit IP + forwarded port.
            name: 'gluetun-ctrl',
            port: controlPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'gluetun-ctrl'),
          },
          {
            // the nginx WebUI-proxy sidecar (containers[2]); the tailnet ingress targets this port.
            name: 'webui',
            port: webuiProxyPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[2].ports[0].name, 'webui'),
          },
        ],
        type: 'ClusterIP',
      },
    },

    // Tailnet-only L7 ingress (no funnel) to kubo's built-in WebUI, fronted by the token-injecting nginx
    // sidecar. The admin RPC stays ClusterIP-only -- only the sidecar's webui port is reachable here.
    // Mirrors lib/qbittorrent.libsonnet's tailscale ingress. tailscaleHostname must be unique tailnet-wide.
    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name + '-webui',
        namespace: namespace,
        annotations: { 'tailscale.com/funnel': 'false' },
      },
      spec: {
        ingressClassName: 'tailscale',
        tls: [{ hosts: [tailscaleHostname] }],
        rules: [{
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: this.service.metadata.name,
                  port: { number: utils.assertEqualAndReturn(this.service.spec.ports[3].port, webuiProxyPort) },
                },
              },
            }],
          },
        }],
      },
    },

    // cert-manager obtains ONE wildcard cert covering the gateway apex + its '*.' wildcard into
    // gatewayCertificate.spec.secretName, in the Ingress's namespace so Traefik can read it. DNS-01
    // needs no inbound reachability to issue; cert-manager creates/cleans the _acme-challenge.<host>
    // TXT in Cloudflare itself. Mirrors lib/test-traefik-acme-ingress.libsonnet.
    gatewayCertificate: {
      apiVersion: 'cert-manager.io/v1',
      kind: 'Certificate',
      metadata: { name: name + '-gateway-wildcard', namespace: namespace },
      spec: {
        secretName: name + '-gateway-wildcard-tls',
        dnsNames: [gatewayBaseDomain, '*.' + gatewayBaseDomain],
        issuerRef: { name: gatewayIssuerName, kind: 'ClusterIssuer' },
      },
    },

    // Public subdomain-gateway ingress: Traefik terminates TLS with the wildcard cert above and proxies
    // both gatewayBaseDomain (path-gateway landing) and '*.'+gatewayBaseDomain (the per-CID
    // <cid>.ipfs.<key> origins) to kubo's ClusterIP gateway port. Traefik on the websecure entrypoint
    // sets X-Forwarded-Proto/Host, so kubo emits correct https subdomain links. The in-cluster hop
    // (Traefik -> Service -> gateway) bypasses the VPN: the gateway port is in gluetun's FIREWALL_INPUT_PORTS.
    gatewayIngress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name + '-gateway',
        namespace: namespace,
        // HTTPS only -- this is a TLS gateway; bind the routers to the websecure entrypoint.
        annotations: { 'traefik.ingress.kubernetes.io/router.entrypoints': 'websecure' },
      },
      spec: {
        ingressClassName: 'traefik',
        tls: [{
          hosts: [gatewayBaseDomain, '*.' + gatewayBaseDomain],
          secretName: utils.assertEqualAndReturn(this.gatewayCertificate.spec.secretName, name + '-gateway-wildcard-tls'),
        }],
        // Both the apex landing and the wildcard subdomains route to the same gateway port; kubo picks
        // path vs subdomain behavior off the Host header (Gateway.PublicGateways, set in the wrapper).
        rules: [
          {
            host: host,
            http: {
              paths: [{
                path: '/',
                pathType: 'Prefix',
                backend: {
                  service: {
                    name: this.service.metadata.name,
                    port: { number: utils.assertEqualAndReturn(this.service.spec.ports[1].port, gatewayPort) },
                  },
                },
              }],
            },
          }
          for host in [gatewayBaseDomain, '*.' + gatewayBaseDomain]
        ],
      },
    },
  },
}
