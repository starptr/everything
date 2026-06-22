local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// gluetun VPN-sidecar BUILDER (https://github.com/qdm12/gluetun). Unlike the other libs this does
// NOT return a Deployment -- it returns embeddable fragments that a HOST lib (e.g. qbittorrent)
// splices into its own pod. gluetun and the app run in the SAME pod, so the app automatically
// shares gluetun's network namespace (a k8s pod is one netns). gluetun's built-in firewall is a
// killswitch (default on): it DROPs every egress that isn't the VPN tunnel, so the app cannot reach
// the internet except through the VPN -- this is the enforcement, applied at the netfilter layer
// below the app, so libtorrent's leak vectors (DHT/uTP/UDP, IPv6, proxy fallback) are all blocked.
//
// The host keeps the pod reachable through the killswitch via two knobs:
//   * FIREWALL_OUTBOUND_SUBNETS -- return traffic to the Service, kubelet probes, and the Tailscale
//     proxy (the cluster pod + service CIDRs).
//   * FIREWALL_INPUT_PORTS      -- inbound to the app's WebUI + gluetun's control server.
//
// The control server (port controlPort) is locked down by default since gluetun v3.39, so we mount
// a config.toml that makes GET /v1/publicip/ip public (auth = "none") -- gluetun's own liveness
// probe and the leak-test both read the VPN exit IP from it. config.toml is non-sensitive (just a
// route allowlist) so it lives in a ConfigMap; only the credentials live in the Secret (and the
// Secret is consumed via envFrom, which can't handle a dotted "config.toml" key -- another reason
// to keep them separate).
//
// Optionally (httpProxy=true) gluetun also serves its built-in HTTP forward proxy on httpProxyPort,
// so a host can expose gluetun itself as a VPN-egress proxy for other workloads (no app container
// needed -- see lib/vpn-proxy.libsonnet). The host must add httpProxyPort to firewallInputPorts (so
// the killswitch lets callers reach it) and publish it on its Service.
{
  new(
    wireguardPrivateKey=null,           // required when vpnType == 'wireguard'
    openvpnUser=null,                   // required when vpnType == 'openvpn'
    openvpnPassword=null,
    name='gluetun',                     // container name + secret/configmap prefix
    namespace='default',
    vpnProvider,                        // required: must match the secret + support the features used (e.g. PF), e.g. 'protonvpn'
    vpnType,                            // required: 'wireguard' | 'openvpn' -- must match the credentials below
    serverCountries,                    // required: SERVER_COUNTRIES, e.g. 'United States'
    serverRegions=null,                 // optional SERVER_REGIONS
    tz='America/Los_Angeles',
    controlPort=8000,
    // Cluster CIDRs that must stay reachable through the killswitch (k3s defaults; verified against
    // the methanol cluster: pod 10.42.0.0/16, service 10.43.0.0/16). Re-check if networking changes.
    firewallOutboundSubnets='10.42.0.0/16,10.43.0.0/16',
    firewallInputPorts=[controlPort],   // host adds its app port (e.g. WebUI) too
    // VPN-side port forwarding (NAT-PMP). Off by default; only some providers support it (NOT
    // NordVPN -- ProtonVPN/PIA/etc do). When on, gluetun asks the VPN for an inbound-reachable port
    // so a P2P app can ACCEPT incoming connections (be connectable/seed), and auto-opens that port
    // on the VPN-interface firewall (no FIREWALL_VPN_INPUT_PORTS needed). The forwarded port is
    // DYNAMIC and gluetun re-runs the up command on each (re)assignment, so the host wires the app's
    // listen port to it via portForwardingUpCommand (gluetun substitutes {{PORT}}/{{VPN_INTERFACE}}).
    portForwarding=false,
    portForwardingUpCommand=null,
    portForwardingDownCommand=null,
    // Built-in HTTP forward proxy. Off by default; when on, gluetun listens on httpProxyPort and
    // forwards through the tunnel. The host must include httpProxyPort in firewallInputPorts.
    httpProxy=false,
    httpProxyPort=8888,
    image=images.gluetun.fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,
    assert vpnType == 'wireguard' || vpnType == 'openvpn'
           : "gluetun: vpnType must be 'wireguard' or 'openvpn'",
    assert vpnType != 'wireguard' || wireguardPrivateKey != null
           : 'gluetun: wireguardPrivateKey is required when vpnType == wireguard',
    assert vpnType != 'openvpn' || (openvpnUser != null && openvpnPassword != null)
           : 'gluetun: openvpnUser and openvpnPassword are required when vpnType == openvpn',

    controlPort:: controlPort,          // re-exported so the host can build probes / the Service
    httpProxyPort:: httpProxyPort,      // re-exported (meaningful when httpProxy) so the host can build its Service

    // Control-server auth config: make ONLY GET /v1/publicip/ip public so probes + the leak-test
    // can read the VPN exit IP, while everything else stays locked (gluetun v3.39+ default).
    local controlConfigToml = std.join('\n', [
      '[[roles]]',
      'name = "publicip"',
      'routes = ["GET /v1/publicip/ip"]',
      'auth = "none"',
      '',
    ]),

    configMap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-control', namespace: namespace },
      data: { 'config.toml': controlConfigToml },
    },

    // Credentials only -- consumed via envFrom (so keys must be valid env identifiers).
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-vpn', namespace: namespace },
      type: 'Opaque',
      stringData:
        if vpnType == 'wireguard'
        then { WIREGUARD_PRIVATE_KEY: wireguardPrivateKey }
        else { OPENVPN_USER: openvpnUser, OPENVPN_PASSWORD: openvpnPassword },
    },

    container: {
      name: name,
      image: image,
      env: [
        { name: 'VPN_SERVICE_PROVIDER', value: vpnProvider },
        { name: 'VPN_TYPE', value: vpnType },
        { name: 'SERVER_COUNTRIES', value: serverCountries },
      ] + (if serverRegions != null then [{ name: 'SERVER_REGIONS', value: serverRegions }] else []) + [
        { name: 'TZ', value: tz },
        // Killswitch is on by default; these keep the pod reachable through it.
        { name: 'FIREWALL_OUTBOUND_SUBNETS', value: firewallOutboundSubnets },
        { name: 'FIREWALL_INPUT_PORTS', value: std.join(',', [std.toString(p) for p in firewallInputPorts]) },
        { name: 'HTTP_CONTROL_SERVER_ADDRESS', value: ':%d' % controlPort },
        // Restart the tunnel if connectivity dies.
        { name: 'HEALTH_TARGET_ADDRESS', value: 'cloudflare.com:443' },
      ] + (
        // VPN-side NAT-PMP port forwarding -- see the portForwarding param comment above.
        if portForwarding then [
          { name: 'VPN_PORT_FORWARDING', value: 'on' },
          // Needed for WireGuard, where gluetun can't infer the provider's PF code from the tunnel.
          { name: 'VPN_PORT_FORWARDING_PROVIDER', value: vpnProvider },
          { name: 'VPN_PORT_FORWARDING_STATUS_FILE', value: '/tmp/gluetun/forwarded_port' },
          // Only connect to servers that actually support P2P + port forwarding, and skip free
          // servers (which don't offer PF on paid providers like ProtonVPN).
          { name: 'PORT_FORWARD_ONLY', value: 'on' },
          { name: 'FREE_ONLY', value: 'off' },
        ] + (
          // gluetun pipes the up command's stderr to its own logger at ERROR level, so a `wget -nv`
          // up command emits one benign `ERROR [port forwarding] ... [0/0] -> "-" [1]` line at
          // startup -- that's wget's normal success output (0-byte body to stdout), NOT a failure.
          // The port is still set; don't chase it. (Use `wget -q` to silence it, at the cost of also
          // hiding wget's real error output.)
          if portForwardingUpCommand != null
          then [{ name: 'VPN_PORT_FORWARDING_UP_COMMAND', value: portForwardingUpCommand }]
          else []
        ) + (
          if portForwardingDownCommand != null
          then [{ name: 'VPN_PORT_FORWARDING_DOWN_COMMAND', value: portForwardingDownCommand }]
          else []
        ) else []
      ) + (
        // Built-in HTTP forward proxy. HTTPPROXY_LISTENING_ADDRESS defaults to :8888; set it
        // explicitly so httpProxyPort stays the single source of truth for the listen port.
        if httpProxy then [
          { name: 'HTTPPROXY', value: 'on' },
          { name: 'HTTPPROXY_LISTENING_ADDRESS', value: ':%d' % httpProxyPort },
        ] else []
      ),
      envFrom: [{ secretRef: { name: this.secret.metadata.name } }],   // WG key or OVPN creds
      // http-proxy is APPENDED after gluetun-ctrl: ports[0] must stay 'gluetun-ctrl' (the liveness
      // probe below and host Services assert ports[0].name == 'gluetun-ctrl').
      ports: [{ name: 'gluetun-ctrl', containerPort: controlPort }]
             + (if httpProxy then [{ name: 'http-proxy', containerPort: httpProxyPort }] else []),
      securityContext: {
        capabilities: { add: ['NET_ADMIN'] },   // bring up wg/tun + program iptables
      },
      volumeMounts: [
        { name: name + '-tun', mountPath: '/dev/net/tun' },
        { name: name + '-control', mountPath: '/gluetun/auth/config.toml', subPath: 'config.toml', readOnly: true },
      ],
      // publicip route is public (config.toml), so this probe works without auth and fails when the
      // tunnel is down -> gluetun restarts and the shared-netns app loses connectivity until it heals.
      livenessProbe: {
        httpGet: { path: '/v1/publicip/ip', port: utils.assertEqualAndReturn(this.container.ports[0].name, 'gluetun-ctrl') },
        initialDelaySeconds: 30,
        periodSeconds: 30,
        failureThreshold: 5,
      },
      resources: {
        requests: { memory: '64Mi', cpu: '50m' },
        limits: { memory: '256Mi', cpu: '500m' },
      },
    },

    // Volumes the host must add to pod.spec.volumes.
    volumes: [
      { name: name + '-tun', hostPath: { path: '/dev/net/tun', type: 'CharDevice' } },
      { name: name + '-control', configMap: { name: this.configMap.metadata.name } },
    ],

    // NOTE: WireGuard needs net.ipv4.conf.all.src_valid_mark=1, but we deliberately do NOT set it via
    // pod securityContext.sysctls -- it isn't in the kubelet's default safe-sysctl set, so that would
    // get the pod rejected with SysctlForbidden (and would otherwise require a node-level
    // --allowed-unsafe-sysctls change). Instead gluetun sets it itself inside its own network
    // namespace at tunnel bringup (it has NET_ADMIN), which bypasses kubelet sysctl admission.

    // Container-array fragment to prepend to the host's containers (gluetun first, so the tunnel +
    // killswitch are up before the app starts egressing).
    containers:: [this.container],
  },
}
