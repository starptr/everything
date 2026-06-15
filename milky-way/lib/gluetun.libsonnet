local utils = import 'milky-way/lib/utils.libsonnet';
local digests = import 'milky-way/lib/digests.libsonnet';

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
{
  new(
    wireguardPrivateKey=null,           // required when vpnType == 'wireguard'
    openvpnUser=null,                   // required when vpnType == 'openvpn'
    openvpnPassword=null,
    name='gluetun',                     // container name + secret/configmap prefix
    namespace='default',
    vpnProvider='nordvpn',
    vpnType='wireguard',                // 'wireguard' (NordLynx) | 'openvpn'
    serverCountries='United States',    // SERVER_COUNTRIES
    serverRegions=null,                 // optional SERVER_REGIONS
    tz='America/Los_Angeles',
    controlPort=8000,
    // Cluster CIDRs that must stay reachable through the killswitch (k3s defaults; verified against
    // the methanol cluster: pod 10.42.0.0/16, service 10.43.0.0/16). Re-check if networking changes.
    firewallOutboundSubnets='10.42.0.0/16,10.43.0.0/16',
    firewallInputPorts=[controlPort],   // host adds its app port (e.g. WebUI) too
    image=digests.gluetun.fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,
    assert vpnType == 'wireguard' || vpnType == 'openvpn'
           : "gluetun: vpnType must be 'wireguard' or 'openvpn'",
    assert vpnType != 'wireguard' || wireguardPrivateKey != null
           : 'gluetun: wireguardPrivateKey is required when vpnType == wireguard',
    assert vpnType != 'openvpn' || (openvpnUser != null && openvpnPassword != null)
           : 'gluetun: openvpnUser and openvpnPassword are required when vpnType == openvpn',

    controlPort:: controlPort,          // re-exported so the host can build probes / the Service

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
      ],
      envFrom: [{ secretRef: { name: this.secret.metadata.name } }],   // WG key or OVPN creds
      ports: [{ name: 'gluetun-ctrl', containerPort: controlPort }],
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
