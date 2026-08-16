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
// move-organizes. Drop folders + renamer (WebAOM) are set in the WebUI post-deploy.
//
// Like jellyfin, Shoko has no API-key-on-boot to pin -- its config (AniDB creds, import folders,
// renamer, local users) is set during an interactive first-run wizard, so this lib carries NO
// Secret and no config-as-code; it's plain PUID/PGID/TZ. PUID/PGID are 1000/1000 to match
// qbittorrent/sonarr/jellyfin so Shoko owns the same uid-1000 files on the shared volume (hardlinks
// and moves need write access to them).
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
  ):: {
    local this = self,

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
  },
}
