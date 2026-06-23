local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';
local kataRuntimeClass = import 'milky-way/lib/kata-runtime-class.libsonnet';

// grand-central -- a single "one-stop-shop" sshd for jumping into my personal machines no
// matter what NAT/firewall each sits behind. It is a pure relay: nobody gets a shell on it.
//
// There is ONE flat list of authorized participant keys -- no client/target split. A participant
// can act as either or both; which role a machine actually plays is decided on that machine, not
// here (see the Sodium LaunchAgent in venus/.../sodium.nix):
//   * To be a TARGET (reachable), a machine keeps an outbound ssh alive that opens a REMOTE
//     forward on its OWN port, e.g. `ssh -N -R localhost:2222:localhost:22 relay@grand-central:30023`,
//     making its sshd reachable on grand-central's loopback :2222. Each target uses a DISTINCT
//     port, so many targets listen at once.
//   * To act as a CLIENT, a machine ProxyJumps through here to a target's port:
//     `ssh -J relay@grand-central:30023 -p 2222 yuto@localhost`. grand-central only shovels TCP;
//     the client then does an INDEPENDENT, end-to-end ssh handshake with the TARGET's own sshd
//     over that pipe -- so reaching a target is never access, the target authenticates the client.
//
// Everyone authenticates as the single unix user `relay`. authorized_keys options (per key):
//   * `restrict` -> no pty/X11/agent/exec (no shell -- pure relay), even with a stolen key.
//   * `port-forwarding` -> re-enable forwarding that `restrict` turned off.
//   * `permitopen="localhost:*","127.0.0.1:*"` on EVERY key -> may -L/-W to any LOOPBACK port
//     (reach any target's listener) but nothing else. The host bound is load-bearing: a k8s pod
//     has its own netns, so this loopback is only the relay's own sshd + the target pipes, NOT the
//     node / other pods / ClusterIPs / internet. A host-LESS permitopen would make grand-central
//     an open proxy into the cluster -- never do that. (Holds only while the pod stays single-
//     container with nothing sensitive on its loopback.) Since reaching a target is gated by the
//     target's own sshd, per-target permitopen pinning would add ~nothing and is omitted.
//   * `permitlisten="localhost:<port>"` -> OPTIONAL, the one meaningful per-key boundary: which
//     port(s) a key may open a reverse listener (-R) on. A target pins itself to its own port so a
//     leak can't squat another target's; an unpinned key may listen on any loopback port. (There
//     is no valid "deny listening" token -- `permit*="none"` is rejected as an invalid port -- but
//     a squatted port is host-key-protected on the connecting client anyway.)
// Keys are PUBLIC, so they're passed in literally (not via sops), mirroring sftp.libsonnet.
//
// Config is fully DECLARATIVE: the sshd policy and the authorized_keys both live in ConfigMaps
// mounted read-only (the files here ARE the documentation of what runs). The ONLY persisted
// state is the server's host-key identity, on an iSCSI (block, no NFS root-squash) RWO PVC --
// same reasoning as sftp.libsonnet: sshd rejects host keys not owned root:0600, and persisting
// them stops clients hitting "REMOTE HOST IDENTIFICATION HAS CHANGED" on every redeploy. RWO
// forces `strategy: Recreate` (old pod must release the volume first).
{
  new(
    authorizedKeys,                     // positional, required -> list; each entry is either a
                                        // pubkey STRING, or an object { key, listenPorts: [ports] }
                                        // pinning which port(s) that key may open a reverse
                                        // listener (-R) on. See the header for the full model.
    nodePort,                           // positional, required, unique per cluster -> ssh -p <nodePort>
    name='grand-central',
    namespace='default',
    relayUser='relay',                  // the single login user; matches AllowUsers + the image's passwd
    image=images['grand-central'].fullyQualifiedImageReferencePinned,
    hostKeysStorageClassName='my-custom-zfs-generic-iscsi',  // iSCSI/RWO: real root, no NFS squash
    hostKeysStorageSize='1Gi',
  ):: {
    local this = self,

    // Mounted read-only at /etc/grand-central; the image's Cmd points sshd at sshd_config there.
    local configMountPath = '/etc/grand-central',
    local hostKeysMountPath = '/hostkeys',

    // Persist the host-key types sshd_config names below; one source of truth for the seed loop.
    local hostKeyTypes = ['ed25519', 'rsa'],
    // HostKey directives derived from the same list the init container seeds, so the policy and
    // the seeded key files can't drift apart.
    local hostKeyLines = std.join('\n', ['HostKey %s/ssh_host_%s_key' % [hostKeysMountPath, t] for t in hostKeyTypes]),

    // The relay user's single authorized_keys file -- one line per authorizedKeys entry (the
    // trailing newline per line matters: sshd parses one key per line). Every line carries the
    // common options; an object entry's `listenPorts` add a permitlisten pin (see header).
    local commonOpts = ['restrict', 'port-forwarding', 'permitopen="localhost:*"', 'permitopen="127.0.0.1:*"'],
    local renderKeyLine(entry) =
      local key = if std.isString(entry) then entry else entry.key;
      local listenPorts = if std.isString(entry) then [] else (if std.objectHas(entry, 'listenPorts') then entry.listenPorts else []);
      local opts = commonOpts + ['permitlisten="localhost:%d"' % p for p in listenPorts];
      std.join(',', opts) + ' ' + key,
    local authorizedKeysContent = std.join('', [renderKeyLine(e) + '\n' for e in authorizedKeys]),

    local sshdConfig = |||
      # MANAGED BY milky-way/lib/grand-central.libsonnet -- this file is the policy of record.
      Port 22
      AddressFamily inet
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PubkeyAuthentication yes
      AuthenticationMethods publickey
      AuthorizedKeysFile %(configMountPath)s/%%u
      AllowUsers %(relayUser)s
      # The authorized_keys lives on a ConfigMap volume, whose mount dir kubelet creates 0777
      # (world-writable) -- StrictModes would refuse to read keys from under it. That check guards
      # against other local users tampering with a home dir; here the keys are read-only from the
      # ConfigMap and %(relayUser)s is the sole (nologin) user, so there's nothing to tamper.
      StrictModes no

      # Persisted host identity (seeded by the init container onto the iSCSI PVC). Without these,
      # sshd falls back to nonexistent /etc/ssh defaults and exits with "no hostkeys available".
      %(hostKeyLines)s

      # This box exists ONLY to forward TCP between participants; per-key permitopen/permitlisten
      # options (see authorized_keys) bound where each key may forward. GatewayPorts no keeps every
      # reverse listener on loopback, so targets coexist on distinct loopback ports.
      AllowTcpForwarding yes
      GatewayPorts no
      PermitTunnel no
      X11Forwarding no
      AllowAgentForwarding no
      PermitTTY no

      # Reap dead tunnels promptly so a reconnecting target can re-bind the loopback listen port
      # instead of hitting "remote port forwarding failed" against a stale listener.
      ClientAliveInterval 30
      ClientAliveCountMax 3

      # The k8s TCP readiness probe opens and drops a connection every periodSeconds without
      # authenticating. OpenSSH 9.8+ per-source penalties would rack up against the kubelet's
      # probe IP and eventually defer/fail the probe (flapping the pod); the probe source is the
      # cluster, never a real client, so disable the feature here.
      PerSourcePenalties no

      LogLevel VERBOSE
      PidFile none
    ||| % { configMountPath: configMountPath, relayUser: relayUser, hostKeyLines: hostKeyLines },

    // Single declarative ConfigMap: the sshd policy plus the relay user's authorized_keys, both
    // mounted as a directory at /etc/grand-central (sshd reads .../sshd_config and, per
    // AuthorizedKeysFile, .../<relayUser>).
    local configData = {
      'sshd_config': sshdConfig,
      [relayUser]: authorizedKeysContent,
    },

    configMap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-config', namespace: namespace },
      data: configData,
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
            // sshd reads config + authorized_keys once at startup, and ConfigMap edits don't roll
            // a Deployment on their own -- hash the rendered config into the template so any edit
            // (policy OR a key add/remove) rolls the pod. Same checksum gotcha as sftp/qbittorrent.
            annotations: { 'checksum/config': std.md5(std.manifestJsonEx(configData, '')) },
          },
          spec: {
            // Run this internet-facing SSH bastion inside a kata microVM (see
            // lib/kata-runtime-class.libsonnet) so a container/sshd escape is confined to a
            // throwaway guest kernel instead of pivoting into the methanol host node. The only
            // persisted state is the host-key PVC; everything else is the read-only ConfigMap.
            runtimeClassName: kataRuntimeClass.name,
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            initContainers: [
              {
                // Seed each host key only-if-missing onto the iSCSI volume, root-owned 0600, so
                // sshd accepts them and they survive restarts. Reuses the grand-central image
                // (busybox sh + ssh-keygen).
                name: 'init-hostkeys',
                image: image,
                command: ['sh', '-c', (|||
                  set -eu
                  for t in %(types)s; do
                    f="%(dir)s/ssh_host_${t}_key"
                    [ -f "$f" ] || ssh-keygen -q -t "$t" -f "$f" -N ""
                  done
                |||) % { types: std.join(' ', hostKeyTypes), dir: hostKeysMountPath }],
                volumeMounts: [
                  { name: 'hostkeys', mountPath: hostKeysMountPath },
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
                ports: [{ name: 'ssh', containerPort: 22 }],
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath, readOnly: true },
                  { name: 'hostkeys', mountPath: hostKeysMountPath, readOnly: true },
                ],
                readinessProbe: {
                  tcpSocket: { port: 'ssh' },
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
              { name: 'config', configMap: { name: this.configMap.metadata.name } },
              { name: 'hostkeys', persistentVolumeClaim: { claimName: this.hostKeysPvc.metadata.name } },
            ],
          },
        },
      },
    },

    // Public entry: a NodePort on every node (Cilium forwards to wherever the pod runs), reached
    // publicly via grand-central.yuto.sh -> methanol's home IP, with the router forwarding the
    // WAN port to this NodePort. Both target -R traffic and client ProxyJump arrive here.
    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: name, namespace: namespace },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          name: 'ssh',
          port: 22,
          nodePort: nodePort,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'ssh'),
        }],
        type: 'NodePort',
      },
    },
  },
}
