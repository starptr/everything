local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Suwayomi-Server (formerly Tachidesk): a self-hosted manga reader/server that installs Mihon/
// Tachiyomi extensions, downloads chapters from them, and serves everything through a web UI. Run
// here so its bulk media -- downloaded manga AND the local-source library -- lives on the shared
// `mdata` RWX-NFS PVC, while only its own state (server.conf + the SQLite/H2 DB + installed
// extension .apks + a thumbnail cache) stays on a small iSCSI config PVC. It complements, not
// replaces, the anime stack (jellyfin/sonarr/shoko): those never touch manga.
//
// NON-root image: ghcr.io/suwayomi/suwayomi-server runs as UID/GID 1000 (`useradd --uid 1000
// suwayomi`) and takes NO PUID/PGID -- same class as ju1js/seanime, not a LinuxServer image. So,
// exactly like seanime/qui, a freshly provisioned iSCSI config PVC mounts root-owned and the
// uid-1000 app can't create server.conf until a root initContainer chowns it to 1000:1000. That
// init mounts ONLY the config volume (never `media`), which is also why we do NOT use pod-level
// fsGroup -- fsGroup would recursively chown the 1Ti mdata NFS library.
//
// Downloads/local relocation via subPath: Suwayomi's downloads path
// (/home/suwayomi/.local/share/Tachidesk/downloads) is FIXED -- the docker image explicitly refuses
// to configure it and expects you to mount a volume there instead. So we overlay the mdata PVC at
// the downloads dir (subPath `downloads/suwayomi`, matching qbittorrent's downloads/<app>
// convention) and at the local-source dir (subPath `library/Manga (Suwayomi)`, mirroring shoko's
// `library/Anime (Shoko)`). This is a deliberate departure from the stack's usual whole-/data mount:
// those apps mount all of /data because they HARDLINK across downloads/ <-> library/; Suwayomi does
// no cross-tree hardlinking, so scoping it to its own subdirs is correct and keeps its
// per-manga/chapter folder layout out of the anime library/ tree jellyfin/seanime scan. The two
// subdirs live on the root-squashed NFS, so a root init pre-creates them with mkdir+chmod 0777 (a
// root->nobody process owns /data/** and may create/chmod there; a uid-1000 process gets EPERM, and
// chown is EPERM for everyone). Nested k8s mounts (config PVC at the datadir, mdata subPaths overlaid
// under it) are order-independent, unlike the docker "downloads must be first in the volume list"
// quirk.
//
// Config is seed-vs-live like jellyfin/shoko: Suwayomi rewrites server.conf at runtime and the
// rest of first-run (extensions, sources, library) is interactive, so this lib carries NO Secret /
// config-as-code -- it only sets the bind host/port via env. Storage: the datadir holds a SQLite/H2
// DB it rewrites at runtime; SQLite over NFS is unsafe (locking/corruption), so it lives on iSCSI
// (RWO) -- and an RWO PVC means the old pod must release the volume before a new one mounts it, hence
// strategy: Recreate (same contract as jellyfin/seanime/shoko).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    name='suwayomi',
    namespace='default',
    image=images.suwayomi.fullyQualifiedImageReferencePinned,
    initImage=images.busybox.fullyQualifiedImageReferenceTaggedForSuwayomi,  // root chown + mkdir helper
    port=4567,                          // Suwayomi's HTTP server port (BIND_PORT default)
    timezone='America/Los_Angeles',
    // App-level auth (defense-in-depth on top of the tailnet-only ingress). authMode maps to
    // Suwayomi's AUTH_MODE: 'none' | 'basic_auth' | 'simple_login' | 'ui_login'. When != 'none',
    // both credentials must be set (sops-backed) -- they flow through a Secret + secretKeyRef so
    // neither lands in the rendered Deployment manifest. BASIC_AUTH protects the WebUI and the API.
    authMode='none',
    authUsername='',
    authPassword='',
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite/H2 must not be on NFS
    configStorageSize='10Gi',           // datadir holds the DB + extension .apks + a thumbnail cache that grows with the library
    configMountPath='/home/suwayomi/.local/share/Tachidesk',   // Suwayomi datadir: server.conf + DB + extensions + thumbnails
    mediaMountPath='/data',             // whole shared volume mounted here in the init (matches qbittorrent/sonarr/jellyfin)
    downloadsSubdir='downloads/suwayomi',            // mdata subdir overlaid at <datadir>/downloads (downloads/<app> convention)
    localSourceSubdir='library/Manga (Suwayomi)',    // mdata subdir overlaid at <datadir>/local (mirrors shoko's library/Anime (Shoko))
  )::
    // authEnabled is a FUNCTION-BODY local (not an object local) so it's also visible in the computed
    // Secret field name below -- Jsonnet evaluates computed field names in the enclosing scope, where
    // object locals are NOT in scope.
    local authEnabled = authMode != 'none';
    {
    local this = self,

    // Auth is off unless a non-default mode is requested. Fail at eval (not silently open) if a mode
    // is set without both credentials -- these come from sops via main.jsonnet, so an empty one means
    // the secret didn't propagate.
    assert !authEnabled || (authUsername != '' && authPassword != '') :
      name + ": authMode '" + authMode + "' requires a non-empty authUsername + authPassword",

    // Credentials as an Opaque Secret (values from the sops-backed params), only when auth is on.
    // Mirrors the seanime/sonarr stringData idiom; the AUTH_USERNAME/AUTH_PASSWORD env below read
    // these via secretKeyRef so they never appear in the Deployment manifest.
    [if authEnabled then 'secret']: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: { authUsername: authUsername, authPassword: authPassword },
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
            // Non-root UID-1000 image + a shared mdata mount -> chown the config PVC via a root init
            // (never pod fsGroup, which would recurse into the 1Ti NFS lib). See seanime/qui.
            securityContext: { runAsUser: 1000, runAsGroup: 1000 },
            initContainers: [
              // (1) A fresh iSCSI ext4 config PVC mounts root-owned, so the uid-1000 app can't create
              // server.conf. Root-chown it to 1000:1000. Mounts ONLY config (never media).
              {
                name: 'init-config-perms',
                image: initImage,
                command: ['sh', '-c', 'chown -R 1000:1000 ' + configMountPath],
                securityContext: { runAsUser: 0 },
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              },
              // (2) Pre-create the two mdata subPath targets (downloads + local source) so the
              // uid-1000 app can write them and kubelet just binds the existing dirs. Run AS ROOT
              // like shoko's init-library-dir: the NFS root-squashes every writer to nobody(65534),
              // which OWNS /data/** -- so a root->nobody process can mkdir+chmod there whereas a
              // uid-1000 process gets EPERM. mkdir+chmod (not chown), so root-squash doesn't block it.
              // Positional args ($0=sh sentinel, $@=dirs) keep the space/parens in the local subdir
              // safe. Mounts ONLY media.
              {
                name: 'init-media-dirs',
                image: initImage,
                command: [
                  'sh',
                  '-c',
                  'for d in "$@"; do mkdir -p "$d" && chmod 0777 "$d"; done',
                  'sh',
                  mediaMountPath + '/' + downloadsSubdir,
                  mediaMountPath + '/' + localSourceSubdir,
                ],
                securityContext: { runAsUser: 0 },
                volumeMounts: [
                  { name: 'media', mountPath: mediaMountPath },
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
                env: [
                  // Not a LinuxServer image -> no PUID/PGID. Bind all interfaces so the Service can
                  // reach it; BIND_PORT must match the container/Service port below.
                  { name: 'BIND_IP', value: '0.0.0.0' },
                  { name: 'BIND_PORT', value: std.toString(port) },
                  { name: 'TZ', value: timezone },
                ] + (if authEnabled then [
                  // AUTH_MODE is not sensitive (plain value); the credentials come from the Secret
                  // via secretKeyRef. The docker entrypoint folds these into server.conf on boot.
                  { name: 'AUTH_MODE', value: authMode },
                  { name: 'AUTH_USERNAME', valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'authUsername' } } },
                  { name: 'AUTH_PASSWORD', valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'authPassword' } } },
                ] else []),
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                  // Redirect Suwayomi's fixed downloads + local-source dirs onto their own mdata
                  // subdirs (nested under the config mount; k8s handles the overlay order).
                  { name: 'media', mountPath: configMountPath + '/downloads', subPath: downloadsSubdir },
                  { name: 'media', mountPath: configMountPath + '/local', subPath: localSourceSubdir },
                ],
                // No documented unauthenticated health path (and AUTH_MODE gates it), so gate
                // readiness on the server accepting TCP on the webui port -- same rationale as
                // seanime/shoko. initialDelay accommodates JVM warmup.
                readinessProbe: {
                  tcpSocket: { port: 'webui' },
                  initialDelaySeconds: 20,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '2Gi', cpu: '2' },
                },
              },
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

    // Tailnet-only L7 ingress (no funnel), mirroring jellyfin/seanime/shoko/sonarr/qbittorrent.
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
