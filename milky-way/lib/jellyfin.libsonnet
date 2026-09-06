local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Jellyfin (LinuxServer.io): the media SERVER that plays the library the *arr stack builds. It
// reads the same shared `mdata` RWX-NFS PVC that qbittorrent/sonarr mount at /data, so the
// library tree it serves (/data/library/{Animations,TV Shows,...}) is exactly the one Sonarr
// hardlinks completed downloads into -- same PVC, same /data mount path, one filesystem.
//
// Unlike the *arr apps there's no API-key-on-boot to pin (Jellyfin mints credentials during its
// first-run web setup, which is interactive), so this lib carries NO Secret and no servarr-style
// env overrides -- just PUID/PGID/TZ. Jellyfin is also not an *arr app, so buildarr does not
// manage it.
//
// Storage: /config holds a SQLite library DB plus a metadata/artwork cache that Jellyfin rewrites
// at runtime. SQLite over NFS is unsafe (locking/corruption), so /config lives on iSCSI (RWO) --
// and an RWO PVC means the old pod must release the volume before a new one mounts it, hence
// strategy: Recreate (same contract as sonarr). It's sized larger than the *arr config PVCs
// because that artwork/metadata cache grows with the library. The media volume is mounted
// read-write so Jellyfin can manage media and (optionally) store metadata/trickplay alongside it.
//
// Shokofin plugin (declaratively installed): the anime library is served via the Shokofin plugin,
// which Jellyfin loads from a plugin dir on the config PVC. Rather than hand-install it in the UI,
// the `init-shokofin-plugin` init container materializes a PINNED, whale-built plugin dir onto the
// PVC, and autoUpdate is disabled in the baked meta.json so Jellyfin's updater can't replace it.
// This install mechanism (the param + init container) is PERMANENT -- it's how the plugin is managed.
// Only its CONTENTS are currently a backport: stock Shokofin 6.0.5 + one upstream feature
// (`VFS_UseSourceFileAsVersionIdentifier`) not yet in a stable release (see whale/outputs.nix). When
// upstream ships that feature, the whale image drops the patch and packages stock; this lib is unchanged.
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    name='jellyfin',
    namespace='default',
    image=images.jellyfin.fullyQualifiedImageReferencePinned,
    // Patched-Shokofin file-delivery image (see the header + whale/outputs.nix). Set to null to skip
    // the plugin-install init container (e.g. a Jellyfin with no Shoko anime library).
    shokofinPluginImage=images['jellyfin-shokofin-plugin'].fullyQualifiedImageReferencePinned,
    port=8096,                          // Jellyfin's HTTP WebUI/API port
    timezone='America/Los_Angeles',
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='10Gi',           // larger than the *arr config PVCs: holds the metadata/artwork cache
    mediaMountPath='/data',             // whole shared volume mounted here (matches qbittorrent/sonarr's /data)
  ):: {
    local this = self,

    // Install the pinned patched Shokofin plugin dir onto the config PVC before Jellyfin starts.
    // Idempotent + content-addressed: the marker encodes the patched Shokofin.dll's sha256, so a new
    // build reinstalls but a plain restart is a no-op. Clears any other Shoko_* dir so Jellyfin loads
    // exactly our version, and chowns to uid 1000 (the LSIO Jellyfin runtime uid) so it can read the
    // assemblies it loads. The plugin files live at /plugin in the whale image (busybox gives sh/cp).
    local shokofinPluginInstallScript = |||
      set -eu
      plugins=/config/data/plugins
      ver=$(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' /plugin/meta.json | head -1)
      dest="$plugins/Shoko_$ver"
      want=$(sha256sum /plugin/Shokofin.dll | cut -d' ' -f1)
      marker="$dest/.sfvi-$want"
      if [ ! -f "$marker" ]; then
        echo "installing patched Shokofin $ver (Shokofin.dll $want)"
        rm -rf "$plugins"/Shoko_* 2>/dev/null || true
        mkdir -p "$dest"
        cp -a /plugin/. "$dest/"
        : > "$marker"
      else
        echo "patched Shokofin $ver already installed"
      fi
      chown -R 1000:1000 "$dest"
    |||,

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
            // Seed the patched Shokofin plugin onto the config PVC (see the constructor header +
            // shokofinPluginInstallScript). Reuses the whale plugin image purely as a file carrier;
            // runs as root so it can write into /config and chown to uid 1000. Omitted entirely when
            // shokofinPluginImage is null.
            [if shokofinPluginImage != null then 'initContainers']: [
              {
                name: 'init-shokofin-plugin',
                image: shokofinPluginImage,
                command: ['sh', '-c', shokofinPluginInstallScript],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '64Mi', cpu: '200m' },
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
                  { name: 'config', mountPath: '/config' },
                  { name: 'media', mountPath: mediaMountPath },   // read-write: Jellyfin may manage media / store metadata alongside
                ],
                // /health is Jellyfin's unauthenticated health endpoint (returns "Healthy"), so
                // it's a safe readiness signal even before the interactive first-run setup.
                readinessProbe: {
                  httpGet: { path: '/health', port: 'webui' },
                  initialDelaySeconds: 15,
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

    // Tailnet-only L7 ingress (no funnel), mirroring sonarr/prowlarr/qbittorrent.
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
