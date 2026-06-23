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
// RPC API is locked down with API.Authorizations (admin RPC must NEVER be open): the only caller is
// the test service, granted a bearer token scoped to the minimum AllowedPaths needed to verify the
// node (see testAllowedPaths). Storage: the repo (identity/datastore/pinset) is on iSCSI (RWO) --
// the datastore does file locking, unsafe over NFS (same rationale as jellyfin's SQLite) -- so an
// RWO PVC means the old pod must release it before a new one mounts, hence strategy: Recreate.
// ClusterIP-only (no Ingress).
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
  ):: {
    local this = self,

    // Cluster CIDRs (k3s defaults; verified on methanol). Kept reachable through the killswitch so
    // the in-cluster verifier + kubelet probes can reach the gateway/API/ctrl and get return traffic.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',

    // Compact JSON array of the grant, injected into the wrapper as an env var so API.Authorizations
    // is single-sourced from this jsonnet (no newlines, so it embeds cleanly into the shell --json arg).
    local allowedPathsJson = std.manifestJsonEx(testAllowedPaths, '', ''),

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
      ipfs config --bool Swarm.DisableNatPortMap true                  # gluetun owns NAT-PMP (VPN side), not kubo
      # Bound the swarm so gluetun (which tracks every connection in its firewall/netns) doesn't OOM:
      # a pinned mirror that serves/announces pinned content needs no large peer set.
      ipfs config --json Swarm.ConnMgr '{"Type":"basic","LowWater":30,"HighWater":100,"GracePeriod":"20s"}'
      ipfs config --json API.Authorizations \
        "{\"$TEST_AUTH_NAME\":{\"AuthSecret\":\"bearer:$KUBO_TEST_RPC_TOKEN\",\"AllowedPaths\":$ALLOWED_PATHS_JSON}}"

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

      exec ipfs daemon
    |||) % { ipfsPath: ipfsPath, apiPort: apiPort, gatewayPort: gatewayPort, controlPort: controlPort },

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
    // API + control ports through the killswitch (cluster side); the forwarded SWARM port is auto-
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
      firewallInputPorts=[gatewayPort, apiPort, controlPort],
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
      stringData: { KUBO_TEST_RPC_TOKEN: testRpcToken },
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
            annotations: { 'checksum/config': std.md5(wrapperScript + testRpcToken) },
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
                ],
                envFrom: [{ secretRef: { name: this.secret.metadata.name } }],  // KUBO_TEST_RPC_TOKEN
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
            ],
            volumes: this.vpn.volumes + [
              { name: 'repo', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'wrapper', configMap: { name: this.configMapWrapper.metadata.name } },
              { name: 'pf', emptyDir: {} },
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
        ],
        type: 'ClusterIP',
      },
    },
  },
}
