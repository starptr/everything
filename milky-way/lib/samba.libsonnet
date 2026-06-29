local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Samba (SMB/CIFS) server fronting one NFS-backed PVC, exposed over the tailnet. A multi-share
// server: it takes a list of shares, each served from its own subdirectory of the single PVC. A
// share is either GUEST (anonymous read-write) or AUTHENTICATED (restricted to one SMB user), and
// can carry a per-share `timeMachine` flag (macOS Time Machine target).
//
// Exposure is L4/TCP (445): SMB is not HTTP, so the cluster's Traefik / `ingressClassName: tailscale`
// (both L7-HTTP) cannot carry it. Instead a `tailscale.com/expose` ClusterIP Service publishes it as
// a tagged tailnet node `<tailscaleHostname>.<tailnet>.ts.net` (same mechanism as sftp/mopidy) -- a
// plain tagged node, NOT a Tailscale Service/VIP, so it needs none of the L3 ProxyGroup
// autoApprovers/grants dance. (The tailnet ACL must still permit clients to reach the tag on 445.)
//
// ---- Why Time Machine shares MUST be authenticated (learned the hard way on this cluster) ----
// Samba access-checks a session against the share directory's POSIX perms using the *session's own*
// identity, and two cluster facts make a GUEST Time Machine share impossible:
//   * A guest/anonymous session is NOT treated as the directory owner -- it was denied writing to a
//     0755 dir owned by `nobody` even though the owner had write; it only succeeds when the *group*
//     or *world* write bit is set. So a guest share's directory must be made group/world-writable.
//   * For a `fruit:time machine = yes` share, smbd forces the share root to 0700 (owner-only) so each
//     TM destination is private. A guest is never the owner, so it can never create the backup
//     sparsebundle. (A plain guest share is fine; only TM is blocked.)
// An AUTHENTICATED user's session, by contrast, IS treated as the owner, so a TM share works when
// its directory is owned by that user's uid -- then the user writes its own 0700 root normally. This
// is also what macOS expects: it authenticates to network TM destinations.
//
// ---- Directory ownership on the root-squashed NFS PVC ----
// The democratic-csi NFS class provisions each dataset 0777 root:root (see
// my-custom-zfs-nfs-democratic-csi-driver-config.jsonnet) and root-squashes (root -> nobody). smbd
// won't serve a share whose `path` is missing, so an init container creates each subdir. Crucially,
// the subdir must end up owned by the uid that will write it, and root can't chown on a root-squashed
// export -- so each subdir is created by an init container that *runs as that uid* (mkdir in the 0777
// parent is allowed for any uid). Guest subdirs are owned by `nobody` and chmod'd 0777; an
// authenticated share's subdir is owned by that user's uid (smbd then can't force it to 0700 -- root
// is squashed -- so it stays owner-writable, which is exactly what we want).
//
// ---- Auth model ----
// Guest shares: anonymous, no credentials. Authenticated shares: one SMB user, password from a
// sops-backed Opaque Secret (NEVER inline a credential). The image (servercontainers/samba) reads
// accounts from `ACCOUNT_<user>` / `UID_<user>` env; we feed the password via a secretKeyRef.
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> smb://<tailscaleHostname>.<tailnet>.ts.net/<share>
    shares,                             // required, non-empty list (see share spec below)
    users={},                           // { <username>: { uid: <int>, password: <string from sops> } } for authenticated shares
    name='samba',
    namespace='default',
    image=images.samba.fullyQualifiedImageReferencePinned,
    storageClassName='my-custom-zfs-generic-nfs-csi',  // RWX NFS so other workloads can also mount the PVC if needed
    storageSize='1Ti',
    guestUser='nobody',                 // unix user/group guest shares force files to (uid 65534 on this image)
    guestGroup='nobody',
    guestUid=65534,                     // numeric guest uid for the init container that owns guest dirs
  ):: {
    // Share spec (each element of `shares`):
    //   { name:           SMB share name -> smb://<host>/<name>, also the SAMBA_VOLUME_CONFIG label
    //     subPath?:        subdir under the PVC mount (defaults to name)
    //     timeMachine?:    true -> advertise as a macOS Time Machine target (REQUIRES `user`)
    //     timeMachineMaxSize?: e.g. '1T' -> fruit:time machine max size (only with timeMachine)
    //     user?:           SMB username (must be a key in `users`) -> AUTHENTICATED share; omit for GUEST }
    local this = self,
    local basePath = '/data',           // the one PVC mount; each share is a subdir beneath it

    local subPathOf(s) = if std.objectHas(s, 'subPath') then s.subPath else s.name,
    local isTm(s) = std.objectHas(s, 'timeMachine') && s.timeMachine,
    local userOf(s) = if std.objectHas(s, 'user') then s.user else null,
    local isAuth(s) = userOf(s) != null,
    local ownerUidOf(s) = if isAuth(s) then users[userOf(s)].uid else guestUid,

    assert std.length(shares) > 0 : 'samba.new: `shares` must be a non-empty list',
    assert std.all([!isTm(s) || isAuth(s) for s in shares])
           : 'samba.new: a `timeMachine` share must set `user` (guest Time Machine cannot work; see header)',
    assert std.all([!isAuth(s) || std.objectHas(users, userOf(s)) for s in shares])
           : 'samba.new: every share `user` must have an entry in `users`',

    // One smb.conf stanza per share, as a servercontainers SAMBA_VOLUME_CONFIG_* value (it translates
    // ';' -> newline). Authenticated shares restrict to the user and run as that user (so it OWNS its
    // files -- owner perms apply, incl. a TM 0700 root). Guest shares are anonymous + force everything
    // to `nobody`, and crucially FORCE every created file/dir world-writable: a guest session is
    // access-checked as group/other (never the owner), and clients like macOS Finder create dirs with
    // restrictive modes (e.g. 0755), which would then deny guests writing *inside* them. `create/
    // directory mask` is only a ceiling; `force create/directory mode` is the floor that guarantees
    // writability. The share is anonymous, so there's no per-user boundary lost by 0777.
    local stanzaFor(s) = std.join('; ',
      ['[%s]' % s.name, 'path = %s/%s' % [basePath, subPathOf(s)], 'read only = no', 'browseable = yes']
      + (if isAuth(s) then [
           'valid users = %s' % userOf(s),
           'force user = %s' % userOf(s),
           'force group = %s' % userOf(s),
           'create mask = 0664',
           'directory mask = 0775',
         ] else [
           'guest ok = yes',
           'guest only = yes',
           'force user = %s' % guestUser,
           'force group = %s' % guestGroup,
           // Force every guest-created file/dir world-writable. A guest is access-checked as
           // group/other (never the owner), so without this, nested writes get "Permission denied".
           'create mask = 0666',
           'directory mask = 0777',
           'force create mode = 0666',
           'force directory mode = 0777',
           // ...but the force-modes above only govern the plain create path. macOS (SMB unix
           // extensions are off) sets a security descriptor on new folders that Samba maps to a
           // restrictive mode (0755), bypassing them. `nt acl support = no` makes smbd ignore
           // client-set ACLs, so the mode comes purely from the force-modes -> always 0777.
           // (The Samba-3 `*security mode` floor params that used to cover this were removed in 4.x.)
           'nt acl support = no',
         ])
      + (if isTm(s) then ['fruit:time machine = yes'] else [])
      + (if isTm(s) && std.objectHas(s, 'timeMachineMaxSize') && s.timeMachineMaxSize != null
         then ['fruit:time machine max size = %s' % s.timeMachineMaxSize] else [])),

    // Distinct owner uids -> one init container each (runs AS that uid, since root can't chown on the
    // root-squashed NFS export). Guest dirs additionally get chmod 0777 (a guest session is checked
    // as group/world, not owner -- see header).
    local ownerUids = std.set([ownerUidOf(s) for s in shares]),
    local sharesForUid(uid) = [s for s in shares if ownerUidOf(s) == uid],
    local mkdirCmdFor(uid) = std.join('\n', ['set -eu'] + std.flattenArrays([
      ['mkdir -p %s/%s' % [basePath, subPathOf(s)]]
      + (if uid == guestUid then ['chmod 0777 %s/%s' % [basePath, subPathOf(s)]] else [])
      for s in sharesForUid(uid)
    ])),

    // Accounts for authenticated shares: passwords in an Opaque Secret (from sops), injected via
    // ACCOUNT_<user> secretKeyRef + UID_<user>. Only present when there are authenticated users.
    [if std.length(users) > 0 then 'secret']: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-accounts', namespace: namespace },
      type: 'Opaque',
      stringData: { [u]: users[u].password for u in std.objectFields(users) },
    },

    dataPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-data', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteMany'],   // RWX: the requested "nfs storageclass so multiple workloads can use it"
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
        strategy: { type: 'Recreate' },   // one smbd at a time -> never two writers on a TM sparsebundle during a roll
        selector: { matchLabels: { app: name } },
        template: {
          metadata: { labels: {} + this.deployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            initContainers: [
              {
                // Create each share subdir owned by the uid that will write it (root can't chown on the
                // root-squashed NFS export, so run AS that uid). Reuses the samba image (alpine: sh+mkdir).
                name: 'init-dirs-%d' % uid,
                image: image,
                securityContext: { runAsUser: uid, runAsGroup: uid },
                command: ['sh', '-c', mkdirCmdFor(uid)],
                volumeMounts: [
                  { name: 'data', mountPath: basePath },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              }
              for uid in ownerUids
            ],
            containers: [
              {
                name: name,
                image: image,
                // Accounts (ACCOUNT_<user> password via secretKeyRef + UID_<user>), one
                // SAMBA_VOLUME_CONFIG_<label> per share, and the global map-to-guest so anonymous
                // logins land as guest on guest shares (samba's own default is "Never").
                // servercontainers SAMBA_GLOBAL_CONFIG_<key> escaping: a space in the KEY is `_SPACE_`.
                env: std.flattenArrays([
                  [
                    { name: 'ACCOUNT_' + u, valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: u } } },
                    { name: 'UID_' + u, value: '%d' % users[u].uid },
                  ]
                  for u in std.objectFields(users)
                ]) + [
                  { name: 'SAMBA_VOLUME_CONFIG_' + s.name, value: stanzaFor(s) }
                  for s in shares
                ] + [
                  { name: 'SAMBA_GLOBAL_CONFIG_map_SPACE_to_SPACE_guest', value: 'Bad User' },
                ],
                ports: [{ name: 'smb', containerPort: 445 }],
                volumeMounts: [
                  { name: 'data', mountPath: basePath },
                ],
                readinessProbe: {
                  tcpSocket: { port: 'smb' },
                  initialDelaySeconds: 5,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '64Mi', cpu: '50m' },
                  limits: { memory: '256Mi', cpu: '500m' },
                },
              },
            ],
            volumes: [
              { name: 'data', persistentVolumeClaim: { claimName: this.dataPvc.metadata.name } },
            ],
          },
        },
      },
    },

    // Tailnet path: L4 Service-expose -> a tagged tailnet node serving SMB on port 445.
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
          name: 'smb',
          port: 445,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'smb'),
        }],
        type: 'ClusterIP',
      },
    },
  },
}
