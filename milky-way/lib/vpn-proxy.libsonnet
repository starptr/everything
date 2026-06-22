local utils = import 'milky-way/lib/utils.libsonnet';
local gluetun = import 'milky-way/lib/gluetun.libsonnet';

// A VPN-egress HTTP forward proxy. The pod is gluetun-only: gluetun is BOTH the tunnel and the proxy
// (its built-in HTTP proxy, httpProxy=true on the builder), so there is no app container -- gluetun's
// killswitch forces every forwarded request out through the VPN tunnel, and nothing can leak around
// it. Other workloads (e.g. autobrr's IRC, which speaks HTTP CONNECT) reach it in-cluster at
// http://<name>.<namespace>.svc.cluster.local:<httpProxyPort> and so egress from the VPN exit IP.
//
// This is a HOST of the gluetun builder (lib/gluetun.libsonnet) in the same shape as qbittorrent,
// minus the app container / config PVC / Tailscale ingress: it just splices gluetun's container +
// volumes into a Deployment and publishes the proxy + control ports on a ClusterIP Service.
//
// The proxy needs its OWN WireGuard key (a separate ProtonVPN session from qbittorrent's) -- the same
// key on two concurrent tunnels re-keys/flaps. The key is read from a sops-managed .conf in
// main.jsonnet via wireguard-conf.privateKeyOf, exactly like qbittorrent.
{
  new(
    wireguardPrivateKey,                // positional, required -> gluetun (ProtonVPN/WireGuard)
    name='vpn-proxy',
    namespace='default',
    vpnProvider,                        // required: e.g. 'protonvpn'
    serverCountries,                    // required: SERVER_COUNTRIES, e.g. 'United States'
    httpProxyPort=8888,                 // gluetun's built-in HTTP proxy listen port
  ):: {
    local this = self,
    local controlPort = 8000,           // gluetun control server (publicip route)

    // Cluster CIDRs (k3s defaults; verified on methanol). Kept reachable through the killswitch so
    // in-cluster callers can reach the proxy + control ports and get return traffic.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',

    // The VPN sidecar fragments, embedded into this pod below. httpProxy=true turns gluetun itself
    // into the proxy; firewallInputPorts opens the proxy + control ports through the killswitch.
    vpn:: gluetun.new(
      wireguardPrivateKey=wireguardPrivateKey,
      name=name + '-gluetun',
      namespace=namespace,
      vpnProvider=vpnProvider,
      vpnType='wireguard',
      serverCountries=serverCountries,
      controlPort=controlPort,
      firewallOutboundSubnets='%s,%s' % [podCidr, svcCidr],
      firewallInputPorts=[httpProxyPort, controlPort],
      httpProxy=true,
      httpProxyPort=httpProxyPort,
      // No portForwarding: this is an OUTBOUND forward proxy, it never accepts inbound peer
      // connections, so it needs no NAT-PMP forwarded port.
    ),

    // Re-emit the gluetun-owned manifests so Tanka applies them.
    vpnSecret: this.vpn.secret,
    vpnControlConfig: this.vpn.configMap,

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        // Recreate (not for a PVC -- there is none) so a rollout never runs two gluetun pods at once:
        // two tunnels on the same WireGuard key re-key/flap each other off the VPN session.
        strategy: { type: 'Recreate' },
        selector: { matchLabels: { app: name } },
        template: {
          metadata: { labels: {} + this.deployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // No dnsPolicy:None here (contrast qbittorrent): there is no musl *app* container
            // resolving public names off the k8s resolv.conf. The only resolver is gluetun's HTTP
            // proxy, which runs inside the gluetun container and uses gluetun's own 127.0.0.1 DoT
            // resolver (gluetun rewrites its own /etc/resolv.conf at startup), so the cluster's
            // ndots:5 search domains never reach it -- target hostnames resolve through the tunnel.
            // No pod-level sysctls: gluetun sets WireGuard's src_valid_mark itself inside its netns
            // (see lib/gluetun.libsonnet) -- a pod securityContext.sysctls entry would be rejected
            // with SysctlForbidden.
            containers: this.vpn.containers,
            volumes: this.vpn.volumes,
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
            // The proxy endpoint other workloads dial: http://<name>.<ns>.svc.cluster.local:<port>.
            // gluetun is containers[0]; its http-proxy port is ports[1] (gluetun-ctrl is ports[0]).
            name: 'http-proxy',
            port: httpProxyPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[1].name, 'http-proxy'),
          },
          {
            // gluetun's control port, exposed so the VPN exit IP can be read (GET /v1/publicip/ip).
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
