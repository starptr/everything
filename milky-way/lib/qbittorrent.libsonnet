local utils = import 'milky-way/lib/utils.libsonnet';
local gluetun = import 'milky-way/lib/gluetun.libsonnet';

// Headless qbittorrent whose traffic is forced through a VPN by an embedded gluetun sidecar (see
// lib/gluetun.libsonnet). gluetun + qbittorrent share one network namespace (same pod), and
// gluetun's killswitch makes it impossible for qbittorrent to egress except through the tunnel --
// the only thing reachable from outside is the WebUI, exposed via Tailscale L7 ingress.
//
// Storage: config on iSCSI (RWO) -- qbittorrent rewrites qBittorrent.conf at runtime, so it's
// seeded once (only-if-empty) into the PVC; downloads on NFS (RWX) so other pods (media servers,
// etc.) can mount the completed-downloads tree.
{
  new(
    wireguardPrivateKey,                // positional, required -> gluetun (NordVPN/WireGuard)
    name='qbittorrent',
    namespace='qbittorrent',
    image='lscr.io/linuxserver/qbittorrent:5.2.1@sha256:1784d5a65d08d01de308c7d87ff2c1dba328379e180eeca41cc6b96bdf6a0ffc',
    webuiPort=8080,
    tailscaleHostname='qbittorrent',    // -> https://qbittorrent.<tailnet>.ts.net
    serverCountries='United States',
    configStorageClassName='my-custom-zfs-generic-iscsi',     // RWO
    configStorageSize='5Gi',
    downloadsStorageClassName='my-custom-zfs-generic-nfs-csi',  // RWX, shareable
    downloadsStorageSize='100Gi',
    initImage='busybox:1.37',
  ):: {
    local this = self,
    local controlPort = 8000,           // gluetun control server (publicip route)

    // Cluster CIDRs (k3s defaults; verified on methanol). Used for the killswitch allowlist AND the
    // qbittorrent reverse-proxy / auth-subnet whitelist below.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',

    // The VPN sidecar fragments, embedded into this pod below.
    vpn:: gluetun.new(
      wireguardPrivateKey=wireguardPrivateKey,
      name=name + '-gluetun',
      namespace=namespace,
      vpnType='wireguard',
      serverCountries=serverCountries,
      controlPort=controlPort,
      firewallOutboundSubnets='%s,%s' % [podCidr, svcCidr],
      firewallInputPorts=[webuiPort, controlPort],
    ),

    // Seed qBittorrent.conf. WebUI keys make the WebUI work behind the Tailscale proxy:
    //   * HostHeaderValidation/CSRF/Clickjacking off + ReverseProxySupport + TrustedReverseProxies:
    //     the proxy forwards Host: <hostname>.<tailnet>.ts.net from a pod-CIDR source, which
    //     qbittorrent would otherwise reject.
    //   * AuthSubnetWhitelist (pod+service CIDRs) bypasses login for in-cluster callers -- this also
    //     covers the Tailscale operator proxy pod, so the tailnet itself is the auth boundary (same
    //     model as openclaw) and the leak-test needs no credentials.
    local qbtConf = std.join('\n', [
      '[Application]',
      'FileLogger\\Enabled=true',
      '',
      '[BitTorrent]',
      'Session\\DefaultSavePath=/downloads',
      'Session\\Port=6881',
      '',
      '[Preferences]',
      'WebUI\\Address=*',
      'WebUI\\Port=%d' % webuiPort,
      'WebUI\\HostHeaderValidation=false',
      'WebUI\\CSRFProtection=false',
      'WebUI\\ClickjackingProtection=false',
      'WebUI\\ReverseProxySupportEnabled=true',
      'WebUI\\TrustedReverseProxiesList=%s,%s' % [podCidr, svcCidr],
      'WebUI\\AuthSubnetWhitelistEnabled=true',
      'WebUI\\AuthSubnetWhitelist=%s, %s, 127.0.0.0/8' % [podCidr, svcCidr],
      'WebUI\\LocalHostAuth=false',
      'WebUI\\Username=admin',
      '',
    ]),
    local configData = { 'qBittorrent.conf': qbtConf },

    namespace_: {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: namespace },
    },

    // Re-emit the gluetun-owned manifests so Tanka applies them.
    vpnSecret: this.vpn.secret,
    vpnControlConfig: this.vpn.configMap,

    configMap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-config', namespace: namespace },
      data: configData,
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

    downloadsPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-downloads', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteMany'],   // RWX (NFS) so other pods can mount completed downloads
        storageClassName: downloadsStorageClassName,
        resources: { requests: { storage: downloadsStorageSize } },
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
            annotations: { 'checksum/config': std.md5(std.manifestJsonEx(configData, '')) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // No pod-level sysctls: gluetun sets WireGuard's src_valid_mark itself inside its netns
            // (see lib/gluetun.libsonnet) -- a pod securityContext.sysctls entry would be rejected
            // with SysctlForbidden.
            initContainers: [
              {
                // Seed qBittorrent.conf only when missing/empty so qbittorrent's runtime rewrites of
                // the file persist across restarts (mirrors openclaw's init-config seed pattern).
                name: 'init-config',
                image: initImage,
                command: ['sh', '-c', |||
                  set -eu
                  mkdir -p /config/qBittorrent
                  [ -s /config/qBittorrent/qBittorrent.conf ] \
                    || cp /seed/qBittorrent.conf /config/qBittorrent/qBittorrent.conf
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
            // gluetun FIRST (tunnel + killswitch up before the app egresses), then qbittorrent, which
            // shares gluetun's netns automatically (same pod) -- no netns/cap settings of its own.
            containers: this.vpn.containers + [
              {
                name: name,
                image: image,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: 'America/Los_Angeles' },
                  { name: 'WEBUI_PORT', value: std.toString(webuiPort) },
                ],
                ports: [{ name: 'webui', containerPort: webuiPort }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'downloads', mountPath: '/downloads' },
                ],
                readinessProbe: {
                  httpGet: { path: '/', port: 'webui' },
                  initialDelaySeconds: 20,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '2Gi', cpu: '1' },
                },
              },
            ],
            volumes: this.vpn.volumes + [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'downloads', persistentVolumeClaim: { claimName: this.downloadsPvc.metadata.name } },
              { name: 'config-seed', configMap: { name: this.configMap.metadata.name } },
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
            // qbittorrent is the 2nd container (gluetun is [0]); assert its port is named 'webui'.
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[1].ports[0].name, 'webui'),
          },
          {
            // gluetun's control port, exposed so the leak-test can read the VPN exit IP via Service DNS.
            name: 'gluetun-ctrl',
            port: controlPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'gluetun-ctrl'),
          },
        ],
        type: 'ClusterIP',
      },
    },

    // Tailnet-only L7 ingress (no funnel), mirroring lib/test-tailscale-operator-ingress.libsonnet.
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
