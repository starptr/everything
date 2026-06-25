local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Seanime: self-hosted anime/manga media server (web UI + AniList sync) for the library the *arr
// stack builds on the shared `mdata` RWX-NFS PVC. It reads the same /data/library/... tree that
// jellyfin/sonarr/qbittorrent mount -- same PVC, same /data mount path -- but only ever READS it:
// Seanime scans and streams the files and tracks watch progress in its OWN SQLite DB, it never
// writes the library. So the media mount can be exposed read-only (mediaReadOnly), which is the
// point of the `seanime-ro` instance in main.jsonnet. (Auto-download / file-management features
// need a writable library; a read-only instance forgoes them by design.)
//
// There is no official Seanime container image (upstream ships binaries + an Electron desktop app),
// so we default to ju1js/seanime, the minimal single-purpose community build -- pinned by digest in
// images.libsonnet. It is NOT a LinuxServer image: it already runs as UID 1000 (the same uid that
// owns the mdata files, so reads succeed) and takes no PUID/PGID/TZ -- only SEANIME_SERVER_HOST/PORT.
//
// Remote access / serverPassword: Seanime's CSRF guard (internal/handlers/local_security.go) gates
// privileged settings mutations (the default media-player / torrent-client paths -- an exec-path RCE
// vector) behind a server password OR a genuinely local origin. A tailnet hostname is neither, so
// over the L7 ingress those actions -- including the final onboarding "Launch Seanime" step -- fail
// with "this action requires either a server password or a trusted local origin", and an Origin
// allowlist does NOT satisfy this particular guard. Setting a server password does: every guard
// short-circuits when server.password != "" and Seanime's auth middleware then enforces login. We
// pass it via the --password flag sourced from a sops-backed Secret (env var -> $(SEANIME_PASSWORD));
// Seanime reads no env/config knob for the password directly. Leave serverPassword='' for a
// passwordless instance (local / trusted-origin use only).
//
// Storage: the datadir (config.toml + a SQLite DB + a metadata/image cache) is rewritten at runtime.
// SQLite over NFS is unsafe (locking/corruption), so the datadir lives on iSCSI (RWO) -- and an RWO
// PVC means the old pod must release the volume before a new one mounts it, hence strategy: Recreate
// (same contract as jellyfin/sonarr).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    name='seanime',
    namespace='default',
    image=images.seanime.fullyQualifiedImageReferencePinned,
    permsInitImage=images.busybox.fullyQualifiedImageReferenceTaggedForSeanime,  // root chown of the config PVC
    serverPassword='',                  // sops-backed; when set, enables the UI login + remote privileged actions
    port=43211,                         // Seanime's HTTP server port (SEANIME_SERVER_PORT default)
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='10Gi',           // datadir holds SQLite + a metadata/image cache that grows with the library
    configMountPath='/home/seanime/.config/Seanime',        // ju1js datadir: config.toml + SQLite + cache
    mediaMountPath='/data',             // whole shared volume mounted here (matches qbittorrent/sonarr/jellyfin)
    mediaReadOnly=false,                // expose the media PVC read-only when true (sftp `dataReadOnly` precedent)
  ):: {
    local this = self,

    // Server password as an Opaque Secret (value from the sops-backed `serverPassword` param), only
    // when one is set. Mirrors the sonarr/openclaw stringData idiom; the --password flag below reads
    // it via a secretKeyRef env var.
    [if serverPassword != '' then 'secret']: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: { password: serverPassword },
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
          metadata: { labels: {} + this.deployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // ju1js/seanime runs as UID 1000 (non-root) and can't chown its own datadir, but a
            // freshly provisioned iSCSI volume mounts root-owned -> Seanime gets "permission denied"
            // creating config.toml. Fix it the way LinuxServer images do internally: a root
            // initContainer chowns the config PVC to 1000:1000 before the app starts. It mounts ONLY
            // the config volume (never `media`), so the shared mdata library is never touched -- which
            // is also why we don't use pod-level fsGroup (that would recursively chown the 1Ti NFS lib).
            initContainers: [
              {
                name: 'init-config-perms',
                image: permsInitImage,
                command: ['sh', '-c', 'chown -R 1000:1000 ' + configMountPath],
                securityContext: { runAsUser: 0 },
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                ],
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                env: [
                  // Not a LinuxServer image -> no PUID/PGID/TZ. Bind all interfaces so the Service
                  // can reach it; SEANIME_SERVER_PORT must match the container/Service port below.
                  { name: 'SEANIME_SERVER_HOST', value: '0.0.0.0' },
                  { name: 'SEANIME_SERVER_PORT', value: std.toString(port) },
                ] + (if serverPassword != '' then [
                  // Read by the --password flag below ($(SEANIME_PASSWORD)); Seanime doesn't consume
                  // this env var itself. Sourced from the Secret so it's not inlined in the manifest.
                  { name: 'SEANIME_PASSWORD', valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'password' } } },
                ] else []),
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                  // read-only when mediaReadOnly: Seanime only scans/streams the shared library, it
                  // never writes it (watch state goes to its own SQLite DB on the config PVC).
                  { name: 'media', mountPath: mediaMountPath } + (if mediaReadOnly then { readOnly: true } else {}),
                ],
                // Seanime exposes no documented unauthenticated health path, so gate readiness on the
                // server accepting TCP on the webui port rather than probing an HTTP route.
                readinessProbe: {
                  tcpSocket: { port: 'webui' },
                  initialDelaySeconds: 15,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '2Gi', cpu: '2' },
                },
              } + (if serverPassword != '' then {
                // Image default Cmd is [/app/seanime]; override to inject --password, expanded from the
                // env var above. The password lands in the process args -- readable only via pod exec,
                // which is already cluster-admin-level (same exposure class as config.toml on the PVC).
                command: ['/app/seanime', '--password', '$(SEANIME_PASSWORD)'],
              } else {}),
            ],
            volumes: [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'media', persistentVolumeClaim: { claimName: mediaVolumeClaimName } },
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
            port: port,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'webui'),
          },
        ],
        type: 'ClusterIP',
      },
    },

    // Tailnet-only L7 ingress (no funnel), mirroring jellyfin/sonarr/prowlarr/qbittorrent.
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
                  port: { number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, port) },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
