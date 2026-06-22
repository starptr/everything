local utils = import 'milky-way/lib/utils.libsonnet';
local gluetun = import 'milky-way/lib/gluetun.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// TheLounge: a self-hosted web IRC client, run in PRIVATE mode (config.js public:false -> named
// users log in, and their IRC connections persist even while they're not using the client).
//
// IP hiding is done at the NETWORK layer, not the app layer. TheLounge has no setting to send its
// IRC connections through a proxy (HTTP CONNECT or SOCKS) -- so it CANNOT use the standalone
// vpn-proxy (lib/vpn-proxy.libsonnet, an HTTP-CONNECT proxy autobrr's IRC uses). Instead we embed a
// gluetun sidecar in TheLounge's own pod (the exact qbittorrent pattern, see lib/gluetun.libsonnet):
// gluetun + TheLounge share one network namespace, and gluetun's killswitch makes it impossible for
// TheLounge to egress except through the ProtonVPN/WireGuard tunnel -- so every IRC connection (and
// every link-preview fetch) leaves from the VPN exit IP, never the home IP. The only thing reachable
// from outside is the WebUI, exposed via Tailscale L7 ingress.
//
// The tunnel needs its OWN WireGuard key (a separate ProtonVPN session from qbittorrent and the
// vpn-proxy) -- the same key on two concurrent tunnels re-keys/flaps. The key is read from a
// sops-managed .conf in main.jsonnet via wireguard-conf.privateKeyOf, exactly like qbittorrent.
//
// No port forwarding (contrast qbittorrent): TheLounge only dials OUT to IRC servers, it never
// accepts inbound peer connections, so it needs no NAT-PMP forwarded port. The WebUI inbound path is
// the Tailscale proxy reaching the pod over the cluster CIDR (allowed by the killswitch), not the VPN.
//
// Storage: /config holds config.js, the per-user account JSON (created by `thelounge add`), and the
// SQLite message store. SQLite over NFS is unsafe (locking/corruption), so /config lives on iSCSI
// (RWO) -- an RWO PVC means the old pod must release the volume before a new one mounts it, hence
// strategy: Recreate.
//
// SEEDED vs DECLARATIVE -- read before editing: config.js is SEEDED, not declarative. The
// LinuxServer image generates a default config.js on first boot and users may edit it (or TheLounge
// rewrites parts of /config at runtime), so we seed config.js only-if-empty into the PVC and let the
// running app own it thereafter -- hence the InitialSeed naming (see lib/CLAUDE.md). Create logins
// post-deploy: `kubectl --context methanol exec deploy/<name> -- s6-setuidgid abc thelounge add <user>`.
{
  new(
    wireguardPrivateKey,                // positional, required -> gluetun (ProtonVPN/WireGuard)
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    vpnProvider,                        // required: e.g. 'protonvpn'
    serverCountries,                    // required: SERVER_COUNTRIES, e.g. 'United States'
    name='thelounge',
    namespace='default',
    image=images.thelounge.fullyQualifiedImageReferencePinned,
    webuiPort=9000,                     // TheLounge's default HTTP port
    timezone='America/Los_Angeles',
    public=false,                       // PRIVATE mode: users must log in (see header)
    configStorageClassName='my-custom-zfs-generic-iscsi',     // RWO; SQLite must not be on NFS
    configStorageSize='5Gi',
    initImage=images.busybox.fullyQualifiedImageReferenceTaggedForThelounge,
  ):: {
    local this = self,
    local controlPort = 8000,           // gluetun control server (publicip route)

    // Cluster CIDRs (k3s defaults; verified on methanol). Kept reachable through the killswitch so
    // the Tailscale proxy + kubelet probes can reach the WebUI and get return traffic.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',

    // Seed config.js. public:false is PRIVATE mode. reverseProxy:true so TheLounge honors the
    // X-Forwarded-For the Tailscale proxy sets. host is left at its default (all interfaces) -- NOT
    // 127.0.0.1 -- so the ClusterIP Service can reach the pod (the proxy connects to the pod IP, not
    // loopback). TLS is terminated at the Tailscale ingress, so the app speaks plain HTTP.
    local configJsInitialSeed = std.join('\n', [
      '"use strict";',
      'module.exports = {',
      '  public: %s,' % (if public then 'true' else 'false'),
      '  reverseProxy: true,',
      '  port: %d,' % webuiPort,
      '  https: { enable: false },',
      '};',
      '',
    ]),
    local configDataInitialSeed = { 'config.js': configJsInitialSeed },

    // The VPN sidecar fragments, embedded into this pod below. firewallInputPorts opens the WebUI +
    // control ports through the killswitch so the Tailscale proxy and probes can reach them.
    vpn:: gluetun.new(
      wireguardPrivateKey=wireguardPrivateKey,
      name=name + '-gluetun',
      namespace=namespace,
      vpnProvider=vpnProvider,
      vpnType='wireguard',
      serverCountries=serverCountries,
      controlPort=controlPort,
      firewallOutboundSubnets='%s,%s' % [podCidr, svcCidr],
      firewallInputPorts=[webuiPort, controlPort],
      // No portForwarding (outbound-only IRC) and no httpProxy.
    ),

    // Re-emit the gluetun-owned manifests so Tanka applies them.
    vpnSecret: this.vpn.secret,
    vpnControlConfig: this.vpn.configMap,

    configMapInitialSeed: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-config', namespace: namespace },
      data: configDataInitialSeed,
    },

    configPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-config', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: configStorageClassName,
        resources: { requests: { storage: configStorageSize } },
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // RWO config PVC: old pod must release before new mounts
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            annotations: { 'checksum/config': std.md5(std.manifestJsonEx(configDataInitialSeed, '')) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // DNS: drop the cluster search domains for this pod (same fix as qbittorrent). The image
            // is Alpine (musl); musl's getaddrinfo honors the k8s-injected `search` + `options
            // ndots:5`, so a public IRC host like irc.libera.chat (2 dots < 5) gets the cluster
            // search domains appended FIRST, the upstream returns authoritative NXDOMAIN for each, and
            // musl fails instead of falling back to the absolute name (glibc would) -- breaking every
            // IRC connection. TheLounge only resolves PUBLIC hosts here (IRC servers), via gluetun's
            // 127.0.0.1 resolver through the tunnel, never an in-cluster name, so the cluster search
            // domains are pure dead weight. dnsPolicy:None drops them; it REQUIRES a nameserver, so we
            // declare gluetun's embedded resolver (127.0.0.1) -- shared via the pod netns -- which is
            // what resolves IRC names through the VPN.
            dnsPolicy: 'None',
            dnsConfig: {
              nameservers: ['127.0.0.1'],
              searches: [],
            },
            // No pod-level sysctls: gluetun sets WireGuard's src_valid_mark itself inside its netns
            // (see lib/gluetun.libsonnet) -- a pod securityContext.sysctls entry would be rejected
            // with SysctlForbidden.
            initContainers: [
              {
                // Seed config.js only when missing/empty so the running app's edits to /config persist
                // across restarts (mirrors qbittorrent's init-config seed). /config is iSCSI (not
                // root-squashed NFS), and the LinuxServer s6 init chowns /config to PUID:PGID itself,
                // so no chown/chmod is needed here.
                name: 'init-config',
                image: initImage,
                command: ['sh', '-c', |||
                  set -eu
                  [ -s /config/config.js ] || cp /seed/config.js /config/config.js
                |||],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'config-seed', mountPath: '/seed', readOnly: true },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              },
            ],
            // gluetun FIRST (tunnel + killswitch up before the app egresses), then TheLounge, which
            // shares gluetun's netns automatically (same pod) -- no netns/cap settings of its own.
            containers: this.vpn.containers + [
              {
                name: name,
                image: image,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: timezone },
                ],
                ports: [{ name: 'webui', containerPort: webuiPort }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                ],
                readinessProbe: {
                  httpGet: { path: '/', port: 'webui' },
                  initialDelaySeconds: 20,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '128Mi', cpu: '50m' },
                  limits: { memory: '512Mi', cpu: '1' },
                },
              },
            ],
            volumes: this.vpn.volumes + [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'config-seed', configMap: { name: this.configMapInitialSeed.metadata.name } },
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
            name: 'webui',
            port: webuiPort,
            // TheLounge is the 2nd container (gluetun is [0]); assert its port is named 'webui'.
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[1].ports[0].name, 'webui'),
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

    // Tailnet-only L7 ingress (no funnel), mirroring qbittorrent/sonarr/autobrr.
    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name,
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
                  port: { number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, webuiPort) },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
