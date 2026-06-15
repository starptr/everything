local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// SFTP front door onto an arbitrary PVC. Mounts the given claim into a chrooted SFTP user's home and
// exposes it over two L4/TCP paths -- SFTP is SSH, not HTTP, so the cluster's Traefik /
// `ingressClassName: tailscale` (both L7-HTTP) cannot carry it:
//   * Tailnet:  an L4 Service-expose (`tailscale.com/expose`) -> a tagged tailnet node
//               `<tailscaleHostname>.<tailnet>.ts.net` (same mechanism as mopidy's MPD port). This
//               is a plain tagged node, NOT a Tailscale Service/VIP, so it needs none of the L3
//               ProxyGroup autoApprovers/grants dance.
//   * LAN:      a NodePort on a fixed port, reached via a node's `.local` mDNS alias. NodePort
//               (not hostPort) so the port is open on every node and Cilium forwards to wherever
//               the pod runs -- multi-node-safe without enabling LoadBalancer IPAM.
//
// Auth is public-key only (atmoz/sftp locks the account for password auth when the password field
// is empty). Authorized keys are PUBLIC, so they're passed in literally rather than via sops.
//
// Two non-obvious storage facts drive the host-key handling below:
//   1. sshd refuses host private keys unless they're owned by root and mode 0600. An NFS-backed PVC
//      typically root-squashes (see qbittorrent.libsonnet), so a root-written file there lands owned
//      by `nobody` and sshd would reject it. Host keys therefore live on a dedicated iSCSI (block,
//      no squash) RWO PVC instead, which forces `strategy: Recreate` (the old pod must release the
//      volume). This is independent of whatever PVC is being exposed.
//   2. Without persisted host keys, atmoz regenerates them every boot and clients hit "REMOTE HOST
//      IDENTIFICATION HAS CHANGED". An init container seeds them once (only-if-missing); the main
//      container subPath-mounts each key file into /etc/ssh so atmoz's `ssh-keygen -A` finds them
//      and regenerates nothing.
{
  new(
    claimName,                          // positional, required -> the PVC to expose over SFTP
    authorizedKeys,                     // positional, required -> list of public-key strings
    nodePort,                           // positional, required, must be unique per instance -> sftp -P <nodePort> <user>@<node>.local
    name='sftp',
    namespace='default',                // must match claimName's namespace (PVCs are namespaced)
    image=images['atmoz-sftp'].fullyQualifiedImageReferencePinned,
    sftpUser='sftp',                    // login user; set uid/gid to match the PVC's file ownership
    sftpUid=1000,
    sftpGid=1000,
    dataDirName='data',                 // subdir under the chroot home where the PVC is mounted
    dataReadOnly=false,                 // expose the PVC read-only when true
    tailscaleHostname=name,             // -> sftp <user>@<tailscaleHostname>.<tailnet>.ts.net
    hostKeysStorageClassName='my-custom-zfs-generic-iscsi',  // iSCSI/RWO: real root, no NFS squash
    hostKeysStorageSize='1Gi',
  ):: {
    local this = self,

    // Inside the sshd chroot (ChrootDirectory = the user's home) the user sees this as /<dataDirName>.
    local dataMountPath = '/home/%s/%s' % [sftpUser, dataDirName],
    local keysMountPath = '/home/%s/.ssh/keys' % sftpUser,  // atmoz appends every file here to authorized_keys

    // Persist all three host-key types so no client (whatever HostKeyAlgorithms it negotiates) ever
    // sees a changed key. One source of truth for the init shell loop and the subPath mounts.
    local hostKeyTypes = ['rsa', 'ecdsa', 'ed25519'],
    local hostKeyFiles = std.flattenArrays([
      ['ssh_host_%s_key' % t, 'ssh_host_%s_key.pub' % t]
      for t in hostKeyTypes
    ]),
    local hostKeyMounts = [
      { name: 'hostkeys', mountPath: '/etc/ssh/' + f, subPath: f, readOnly: true }
      for f in hostKeyFiles
    ],

    // Trailing newline per file is REQUIRED: atmoz concatenates every file in .ssh/keys/ into
    // authorized_keys with plain `cat`, so without it two keys merge onto one line and only the
    // first parses (the second is swallowed into the first line's comment field).
    local authorizedKeysData = {
      ['authorized-key-%d.pub' % i]: authorizedKeys[i] + '\n'
      for i in std.range(0, std.length(authorizedKeys) - 1)
    },

    configMapAuthorizedKeys: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-authorized-keys', namespace: namespace },
      data: authorizedKeysData,
    },

    hostKeysPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-hostkeys', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: hostKeysStorageClassName,
        resources: { requests: { storage: hostKeysStorageSize } },
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // RWO host-keys PVC: old pod must release before new mounts
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // atmoz reads authorized_keys once at startup; hash the keys into the template so a key
            // change rolls the pod (a ConfigMap edit alone doesn't), mirroring qbittorrent's checksum.
            annotations: { 'checksum/authorized-keys': std.md5(std.manifestJsonEx(authorizedKeysData, '')) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            initContainers: [
              {
                // Seed each host key only-if-missing onto the iSCSI volume, root-owned 0600, so sshd
                // accepts them and they survive restarts. Reuses the atmoz image (it ships ssh-keygen).
                name: 'init-hostkeys',
                image: image,
                command: ['sh', '-c', (|||
                  set -eu
                  for t in %(types)s; do
                    f="/hostkeys/ssh_host_${t}_key"
                    [ -f "$f" ] || ssh-keygen -q -t "$t" -f "$f" -N ""
                  done
                |||) % { types: std.join(' ', hostKeyTypes) }],
                volumeMounts: [
                  { name: 'hostkeys', mountPath: '/hostkeys' },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                // atmoz reads user definitions from its args: user:pass[:e][:uid[:gid[:dir...]]].
                // Empty password -> key-only auth.
                args: ['%s::%d:%d' % [sftpUser, sftpUid, sftpGid]],
                ports: [{ name: 'sftp', containerPort: 22 }],
                volumeMounts: [
                  { name: 'data', mountPath: dataMountPath } + (if dataReadOnly then { readOnly: true } else {}),
                  { name: 'authorized-keys', mountPath: keysMountPath, readOnly: true },
                ] + hostKeyMounts,
                readinessProbe: {
                  tcpSocket: { port: 'sftp' },
                  initialDelaySeconds: 5,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '32Mi', cpu: '25m' },
                  limits: { memory: '128Mi', cpu: '200m' },
                },
              },
            ],
            volumes: [
              { name: 'data', persistentVolumeClaim: { claimName: claimName } },
              { name: 'hostkeys', persistentVolumeClaim: { claimName: this.hostKeysPvc.metadata.name } },
              { name: 'authorized-keys', configMap: { name: this.configMapAuthorizedKeys.metadata.name } },
            ],
          },
        },
      },
    },

    // Tailnet path: L4 Service-expose -> a tagged tailnet node serving SFTP on port 22.
    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: name,
        namespace: namespace,
        annotations: {
          'tailscale.com/expose': 'true',
          'tailscale.com/hostname': tailscaleHostname,
        },
      },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          name: 'sftp',
          port: 22,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'sftp'),
        }],
        type: 'ClusterIP',
      },
    },

    // LAN path: NodePort on every node (Cilium forwards to the pod), reached via a `.local` alias.
    nodePortService: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: name + '-nodeport', namespace: namespace },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          name: 'sftp',
          port: 22,
          nodePort: nodePort,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'sftp'),
        }],
        type: 'NodePort',
      },
    },
  },
}
