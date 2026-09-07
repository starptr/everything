local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Shoko Server: an AniDB-hash-based anime cataloguer/organizer -- run here to organize anime you
// download MANUALLY (as opposed to the automated SeaDex -> Sonarr pipeline). It hashes the files it
// finds (ED2K), identifies them against AniDB, and renames+moves them into a tidy library on the
// shared `mdata` RWX-NFS PVC (the same PVC/`/data` mount qbittorrent/sonarr/jellyfin use, so it's
// one filesystem). Shoko is NOT a grabber -- it complements, never replaces, the qbt/Sonarr layer.
//
// The manual workflow: add a torrent in qbittorrent (typically under the `manual` category) and tag
// it `on-finish-hardlink-to-shoko-import` -> qbittorrent's on-complete hook HARDLINKS the finished
// content into a Shoko "drop source" folder (/data/downloads/shoko-drop) -> Shoko's rename-and-move
// organizes it into the drop DESTINATION (`libraryDir` below). Shoko itself CANNOT hardlink (its docs
// say so); its move is an inode-preserving rename *because* source + destination sit on one
// filesystem, so the torrent keeps seeding from downloads/qbittorrent/ AND an organized hardlink lands
// in the library -- one physical copy. The hardlink is made by qbittorrent (see qbittorrent.libsonnet
// `hardlinkOnFinished`, which fires on that tag or the sonarr-for-sdxarr category); Shoko only
// move-organizes. Drop folders + the renamer CONFIG (a custom LuaRenamer "AniDB Seasons" script)
// are set in the WebUI post-deploy; the LuaRenamer PLUGIN itself is bootstrapped onto the config
// PVC by the `init-luarenamer` init container (it is not in the Shoko image, and the default
// renamer silently fails to rename+move files without it -- recognized files then strand in the
// drop source instead of moving to the library).
//
// Shoko's first-run config (AniDB creds, import folders, local users) is set during an interactive
// wizard, so most of it is NOT config-as-code -- it's plain PUID/PGID/TZ (1000/1000, to match
// qbittorrent/sonarr/jellyfin so Shoko owns the same uid-1000 files on the shared volume; hardlinks
// and moves need write access to them). The ONE exception is the LuaRenamer config that
// names+organizes the library: its Lua script lives in Shoko's SQLite DB (serialized as
// version-pinned LZ4-MessagePack, so it can't be seeded as a plain file), so a small
// `renamer-reconcile` Job drives it through Shoko's REST API instead -- it create/updates the
// `AniDB Seasons` config from milky-way/lib/shoko-renamer-anidb-seasons.lua and pins it as the
// DefaultRenamer. The Job authenticates with a sops-backed API key (`apiKey`); when that key is null
// the whole reconciler (Secret + ConfigMap + Job) is omitted and Shoko still deploys, so a fresh
// cluster is never blocked on a key that only exists after Shoko's first-run. See the `apiKey` /
// `renamer*` params + the reconciler resources (renamerReconcile*) below.
//
// Storage: /home/shoko/.shoko is Shoko's config VOLUME -- a SQLite DB plus an AniDB/TMDB
// metadata+image cache it rewrites at runtime. SQLite over NFS is unsafe (locking/corruption), so it
// lives on iSCSI (RWO) -- and an RWO PVC means the old pod must release the volume before a new one
// mounts it, hence strategy: Recreate (same contract as jellyfin/sonarr). Sized larger than the
// *arr config PVCs because that image cache grows with the collection. The media volume is mounted
// read-write so Shoko can move files into and manage the library. Unlike seanime (which runs as a
// bare non-root uid and needs a root init-chown of its config PVC), Shoko's entrypoint runs as root
// and chowns /home/shoko/.shoko to PUID/PGID itself before dropping privileges via gosu -- so no
// config init-chown is needed here (the iSCSI block PVC isn't root-squashed, so that chown works).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    name='shoko',
    namespace='default',
    image=images.shoko.fullyQualifiedImageReferencePinned,
    dirInitImage=images.busybox.fullyQualifiedImageReferenceTaggedForShoko,  // uid-1000 init that mkdirs libraryDir
    port=8111,                          // Shoko's HTTP WebUI + REST API port
    timezone='America/Los_Angeles',
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='20Gi',           // SQLite + AniDB/TMDB metadata+image cache that grows with the collection
    configMountPath='/home/shoko/.shoko',                   // Shoko's config VOLUME (DB + settings + cache)
    mediaMountPath='/data',             // whole shared volume mounted here (matches qbittorrent/sonarr/jellyfin)
    // Shoko's drop DESTINATION import folder: where the renamer move-organizes files into. Pre-created
    // by the init container (below) so it can be added as an Import Folder in the WebUI, which requires
    // the path to already exist. Kept separate from Sonarr's '/data/library/Animations (Seadexarr)'.
    libraryDir='/data/library/Anime (Shoko)',
    // LuaRenamer plugin (the renamer backing the WebUI-configured default renamer config). It is
    // NOT bundled in the Shoko image, and without it the default renamer fails to load so
    // rename+move-on-import silently no-ops and recognized files pile up in the drop source. The
    // `init-luarenamer` init container installs this pinned build onto the config PVC. linux-x64
    // asset (methanol is amd64); bumping luaRenamerVersion re-triggers the install on next boot.
    luaRenamerZipUrl='https://github.com/Mik1ll/LuaRenamer/releases/download/v5.10.3-stable-5.3.1/LuaRenamer_v5.10.3-stable-5.3.1-0-g4f8f6bb_linux-x64.zip',
    luaRenamerZipSha256='bf073cd227509f5340cb36a7c6078a5dd2002e1fef5712bfa585d0ce53054c55',
    luaRenamerVersion='5.10.3-stable-5.3.1',
    // Renamer reconciler (see the header). A sops-backed Shoko API key -> the `renamer-reconcile` Job
    // authenticates with it to manage the LuaRenamer config as code. NULL (the default) omits the
    // whole reconciler so Shoko still deploys without a key; wire it from secrets.shoko.apiKey.
    apiKey=null,
    renamerConfigName='AniDB Seasons',   // the LuaRenamer config this reconciler owns + sets as DefaultRenamer
    renamerScript=importstr 'milky-way/lib/shoko-renamer-anidb-seasons.lua',
  ):: {
    local this = self,

    // LuaRenamer plugin bootstrap (see the `luaRenamer*` params + the `init-luarenamer` init
    // container). Idempotent: skips the network fetch when the pinned version is already unpacked
    // on the config PVC (a marker file), and always re-asserts uid-1000 ownership so the uid-1000
    // Shoko process can read the plugin it loads. Pin values arrive via env (LR_* below).
    local luaRenamerInstallScript = |||
      set -eu
      mkdir -p "$LR_PLUGINS_DIR"
      marker="$LR_PLUGINS_DIR/.luarenamer-$LR_VERSION"
      if [ ! -f "$marker" ] || [ ! -f "$LR_PLUGINS_DIR/LuaRenamer/LuaRenamer.dll" ]; then
        echo "installing LuaRenamer $LR_VERSION"
        tmp="$LR_PLUGINS_DIR/.luarenamer.zip"
        curl -fsSL -o "$tmp" "$LR_URL"
        echo "$LR_SHA  $tmp" | sha256sum -c -
        rm -rf "$LR_PLUGINS_DIR/LuaRenamer"
        unzip -q -o "$tmp" -d "$LR_PLUGINS_DIR"
        rm -f "$tmp" "$LR_PLUGINS_DIR"/.luarenamer-*
        : > "$marker"
      else
        echo "LuaRenamer $LR_VERSION already present"
      fi
      chown -R 1000:1000 "$LR_PLUGINS_DIR"
    |||,

    // Desired LuaRenamer config the reconciler upserts. Mirrors the shape of GET /api/v3/Renamer/
    // Config/<name>: RenamerID = the LuaRenamer plugin, Settings = the plugin's setting list. The four
    // toggles stay false (the script drives illegal-char handling itself via `replace_illegal_chars`),
    // and the Lua lives in the version-controlled .lua file next to this lib.
    local desiredRenamerConfig = {
      RenamerID: 'LuaRenamer',
      Name: renamerConfigName,
      Settings: [
        { Name: 'Script', Value: renamerScript },
        { Name: 'Remove Illegal Characters', Value: false },
        { Name: 'Replace Illegal Characters', Value: false },
        { Name: 'Use Existing Anime Location', Value: false },
        { Name: 'Platform-Dependent Illegal Characters', Value: false },
      ],
    },
    local desiredRenamerConfigJson = std.manifestJsonEx(desiredRenamerConfig, '  '),

    // Surgical RFC-6902 patch that makes our config the default + turns on relocate/rename/move-on-
    // import. `add` acts as replace for existing members, so it's safe whether or not the fields are
    // already set. Baked at eval time (name is known) so the reconcile shell needs no JSON escaping.
    local defaultRenamerPatch = std.manifestJsonEx([
      { op: 'add', path: '/Plugins/Renamer/DefaultRenamer', value: renamerConfigName },
      { op: 'add', path: '/Plugins/Renamer/RelocateOnImport', value: true },
      { op: 'add', path: '/Plugins/Renamer/RenameOnImport', value: true },
      { op: 'add', path: '/Plugins/Renamer/MoveOnImport', value: true },
    ], '  '),

    // The reconcile loop (runs in the Job below, reusing the Shoko image for its curl+jq). Waits for
    // the unauthenticated /Init/Status, then create-or-updates the config (skipping the write when the
    // live config already matches -- idempotent) and ensures it's the default renamer. The desired
    // JSON bodies are mounted read-only at /reconcile from the ConfigMap.
    local renamerReconcileScript = |||
      set -eu
      api="$SHOKO_API"; name="$RENAMER_NAME"
      enc=$(printf %s "$name" | jq -sRr @uri)
      norm() { jq -S '{RenamerID,Name,Settings:(.Settings|sort_by(.Name)|map({Name,Value}))}' "$1"; }
      echo "waiting for Shoko API at $api ..."
      i=0
      until curl -fsS -o /dev/null "$api/Init/Status"; do
        i=$((i + 1)); [ "$i" -ge 150 ] && { echo "timed out waiting for Shoko API"; exit 1; }
        sleep 2
      done
      auth="apikey: $SHOKO_API_KEY"
      code=$(curl -s -o /tmp/cur.json -w '%{http_code}' -H "$auth" "$api/Renamer/Config/$enc")
      if [ "$code" = 200 ]; then
        if [ "$(norm /tmp/cur.json)" = "$(norm /reconcile/config.json)" ]; then
          echo "renamer '$name' already up to date"
        else
          echo "updating renamer '$name'"
          curl -fsS -X PUT -H "$auth" -H 'Content-Type: application/json' \
            --data @/reconcile/config.json "$api/Renamer/Config/$enc" >/dev/null
        fi
      elif [ "$code" = 404 ]; then
        echo "creating renamer '$name'"
        curl -fsS -X POST -H "$auth" -H 'Content-Type: application/json' \
          --data @/reconcile/config.json "$api/Renamer/Config" >/dev/null
      else
        echo "unexpected HTTP $code from GET Renamer/Config"; cat /tmp/cur.json; exit 1
      fi
      cur_default=$(curl -fsS -H "$auth" "$api/Settings" | jq -r '.Plugins.Renamer.DefaultRenamer // ""')
      if [ "$cur_default" = "$name" ]; then
        echo "default renamer already '$name'"
      else
        echo "setting default renamer to '$name'"
        curl -fsS -X PATCH -H "$auth" -H 'Content-Type: application/json-patch+json' \
          --data @/reconcile/default-renamer.patch.json "$api/Settings" >/dev/null \
          || echo "warn: could not set default renamer; set it in the WebUI"
      fi
      echo "renamer reconcile complete."
    |||,

    // Re-run the Job only when the desired config, patch, or reconcile logic changes (Jobs are
    // immutable, so a content change must produce a new object name; ttlSecondsAfterFinished reaps the
    // superseded one). A no-op apply keeps the same name -> the completed Job is left untouched.
    local renamerReconcileHash =
      std.substr(std.md5(desiredRenamerConfigJson + defaultRenamerPatch + renamerReconcileScript), 0, 10),

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
            // Pre-create the drop-destination import folder so the WebUI's "add import folder" (which
            // validates the path exists) accepts it, and chmod it 0777 so the uid-1000 Shoko app can
            // then create series folders + move files into it. Run AS ROOT, exactly like
            // qbittorrent's init-config downloads-dir step: the shared NFS root-squashes every writer
            // to nobody (65534), which is who OWNS /data/library (mode 0755) -- so a root->nobody
            // process is the owner and can create the child there (and chmod it), whereas a uid-1000
            // process is neither the nobody-owner nor covered by the 0755 "other" bits and gets
            // EPERM. This is mkdir+chmod (not chown), so root-squash doesn't block it. It mounts ONLY
            // the media volume; the config PVC is left for Shoko's own entrypoint to chown.
            initContainers: [
              {
                name: 'init-library-dir',
                image: dirInitImage,
                command: ['sh', '-c', 'mkdir -p "$0" && chmod 0777 "$0"', libraryDir],
                volumeMounts: [
                  { name: 'media', mountPath: mediaMountPath },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              },
              {
                // Install the LuaRenamer plugin onto the config PVC before Shoko starts (see the
                // luaRenamer* params). Reuses the Shoko image purely as a tool image -- it already
                // ships curl/unzip/sha256sum and matches the target platform -- with the entrypoint
                // overridden. Runs as root (no gosu) so it can unpack into /config and chown to
                // uid 1000; mounts ONLY the config volume. Idempotent, so a normal restart is a
                // no-op (the plugin persists on the PVC; only a fresh PVC hits the network).
                name: 'init-luarenamer',
                image: image,
                command: ['sh', '-c', luaRenamerInstallScript],
                env: [
                  { name: 'LR_PLUGINS_DIR', value: configMountPath + '/Shoko.CLI/plugins' },
                  { name: 'LR_URL', value: luaRenamerZipUrl },
                  { name: 'LR_SHA', value: luaRenamerZipSha256 },
                  { name: 'LR_VERSION', value: luaRenamerVersion },
                ],
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                ],
                resources: {
                  requests: { memory: '32Mi', cpu: '50m' },
                  limits: { memory: '128Mi', cpu: '250m' },
                },
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: timezone },
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: configMountPath },
                  { name: 'media', mountPath: mediaMountPath },   // read-write: Shoko moves files into the library
                  { name: 'dshm', mountPath: '/dev/shm' },
                ],
                // No documented unauthenticated health path before the interactive first-run, so gate
                // readiness on the server accepting TCP on the webui port (same rationale as seanime).
                readinessProbe: {
                  tcpSocket: { port: 'webui' },
                  initialDelaySeconds: 20,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '512Mi', cpu: '250m' },
                  limits: { memory: '2Gi', cpu: '2' },
                },
              },
            ],
            volumes: [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'media', persistentVolumeClaim: { claimName: mediaVolumeClaimName } },
              // Upstream compose sets shm_size: 256m; k8s' default /dev/shm is 64Mi. Back it with a
              // memory emptyDir so Shoko's image/hash work isn't starved.
              { name: 'dshm', emptyDir: { medium: 'Memory', sizeLimit: '256Mi' } },
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

    // Tailnet-only L7 ingress (no funnel), mirroring jellyfin/seanime/sonarr/qbittorrent.
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

    // --- Renamer reconciler (omitted entirely when apiKey is null; see the header). ---
    // Desired config + default-renamer patch as read-only data for the Job. Fixed-name ConfigMap; the
    // Job that consumes it is name-hashed, so a content change rolls a fresh run off the new data.
    [if apiKey != null then 'renamerReconcileConfigMap']: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-renamer-reconcile', namespace: namespace },
      data: {
        'config.json': desiredRenamerConfigJson,
        'default-renamer.patch.json': defaultRenamerPatch,
      },
    },

    // The Shoko API key the Job authenticates with (sops-backed, injected via secretKeyRef so it
    // never lands in the Job spec).
    [if apiKey != null then 'renamerReconcileSecret']: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-renamer-reconcile', namespace: namespace },
      stringData: { apiKey: apiKey },
    },

    // One-shot reconcile Job. Reuses the Shoko image purely for its curl+jq (command overridden, so
    // Shoko's entrypoint never runs); reaches the API over the in-cluster Service. OnFailure +
    // backoffLimit rides out a slow Shoko startup; ttlSecondsAfterFinished reaps it (and superseded
    // hashes) after a day. Name-hashed on the desired content, so an unchanged apply leaves it be.
    [if apiKey != null then 'renamerReconcileJob']: {
      apiVersion: 'batch/v1',
      kind: 'Job',
      metadata: { name: name + '-renamer-reconcile-' + renamerReconcileHash, namespace: namespace },
      spec: {
        ttlSecondsAfterFinished: 86400,
        backoffLimit: 30,
        template: {
          metadata: { labels: { app: name + '-renamer-reconcile' } },
          spec: {
            restartPolicy: 'OnFailure',
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: 'reconcile',
                image: image,
                command: ['sh', '-c', renamerReconcileScript],
                env: [
                  { name: 'SHOKO_API', value: 'http://%s.%s.svc:%d/api/v3' % [name, namespace, port] },
                  { name: 'RENAMER_NAME', value: renamerConfigName },
                  {
                    name: 'SHOKO_API_KEY',
                    valueFrom: { secretKeyRef: { name: name + '-renamer-reconcile', key: 'apiKey' } },
                  },
                ],
                volumeMounts: [
                  { name: 'reconcile', mountPath: '/reconcile', readOnly: true },
                ],
                resources: {
                  requests: { memory: '32Mi', cpu: '25m' },
                  limits: { memory: '128Mi', cpu: '250m' },
                },
              },
            ],
            volumes: [
              { name: 'reconcile', configMap: { name: name + '-renamer-reconcile' } },
            ],
          },
        },
      },
    },
  },
}
