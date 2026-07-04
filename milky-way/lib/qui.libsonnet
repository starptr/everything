local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// qui (by autobrr): a fast, modern, multi-instance WebUI for qBittorrent -- a nicer front-end than
// qBittorrent's built-in WebUI over the gluetun-fronted `qbittorrent` in main.jsonnet, plus
// filesystem features (orphan scan, hardlink/reflink, automations). It reaches qBittorrent in-cluster
// at http://qbittorrent.default.svc.cluster.local:8080 with NO credentials -- qBittorrent's
// AuthSubnetWhitelist bypasses auth for in-cluster callers (same as buildarr/seadexarr/Sonarr).
//
// SEEDED vs DECLARATIVE -- read before editing: qui's qBittorrent instance list (and users) are
// RUNTIME state in its SQLite DB, added in the web UI after deploy. qui has no config-as-code path
// for them (contrast buildarr/seadexarr), so nothing here wires the qBittorrent connection -- you add
// it in qui's UI post-deploy. config is likewise self-managed: qui generates config.toml on first
// boot -- including a random sessionSecret it PERSISTS to /config -- so we pin nothing there and let
// it self-manage (a session-secret change breaks decryption of stored instance passwords). We only
// override host/port via QUI__* env vars (they win over config.toml each boot), mirroring autobrr.
//
// Local Filesystem Access: qui's orphan-scan / hardlink / reflink / automation features need qui to
// see the SAME paths qBittorrent uses, at the SAME mount path -- so we mount the shared mdata volume
// read-write at /data (matching qbittorrent/sonarr). Enable "Local Filesystem Access" per-instance in
// qui's UI post-deploy for it to use this mount. (Without the mount, qui still works fully as a WebUI;
// only these file features are unavailable.)
//
// Storage: /config holds a SQLite DB + a config.toml qui rewrites at runtime. SQLite over NFS is
// unsafe (locking/corruption), so config lives on iSCSI (RWO) -- and an RWO PVC means the old pod must
// release the volume before a new one mounts it, hence strategy: Recreate. WebUI over Tailscale L7.
//
// UID handling: the qui image is alpine and runs as ROOT by default (no USER), but we deliberately run
// it as uid 1000 -- the uid that owns the mdata library the *arr stack builds -- so its writes into
// /data land with the right ownership (root would be squashed to nobody on the NFS). uid 1000 can't
// chown a freshly provisioned iSCSI /config, so a root initContainer chowns the config PVC to 1000
// first (the seanime pattern). We do NOT use pod-level fsGroup: it would recursively chown the 1Ti
// mdata NFS mount (the nonroot-image-init-chown footgun) -- the init chowns ONLY /config.
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    name='qui',
    namespace='default',
    image=images.qui.fullyQualifiedImageReferencePinned,
    permsInitImage=images.busybox.fullyQualifiedImageReferenceTaggedForQui,  // root chown of the config PVC
    port=7476,                          // qui's WebUI/API port (QUI__PORT default)
    timezone='America/Los_Angeles',
    mediaMountPath='/data',             // MUST match qBittorrent's mount so file paths line up (qui requirement)
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='5Gi',
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
            // We run qui as uid/gid 1000 (see header): a root initContainer chowns the freshly
            // provisioned iSCSI /config to 1000 so uid 1000 can create its DB/config there. It mounts
            // ONLY the config volume (never `media`), so the shared mdata NFS is never touched -- which
            // is also why we don't use pod-level fsGroup (that would recursively chown the 1Ti lib).
            securityContext: { runAsUser: 1000, runAsGroup: 1000 },
            initContainers: [
              {
                name: 'init-config-perms',
                image: permsInitImage,
                command: ['sh', '-c', 'chown -R 1000:1000 /config'],
                securityContext: { runAsUser: 0 },
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                ],
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                // QUI__<KEY> env vars override config.toml on every boot (same idea as autobrr's
                // AUTOBRR__* overrides). No QUI__SESSION_SECRET: qui generates one on first boot and
                // persists it to config.toml on the PVC.
                env: [
                  { name: 'TZ', value: timezone },
                  { name: 'QUI__HOST', value: '0.0.0.0' },   // bind all interfaces so the Service reaches it
                  { name: 'QUI__PORT', value: std.toString(port) },   // explicit; same source as containerPort/Service
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  // read-write: qui's hardlink/reflink/orphan/automation features write the shared
                  // library. mediaMountPath MUST equal qBittorrent's mount (/data) so paths line up.
                  { name: 'media', mountPath: mediaMountPath },
                ],
                // qui's own image HEALTHCHECK hits this unauthenticated path -- a safe readiness signal
                // even before first-run account setup.
                readinessProbe: {
                  httpGet: { path: '/health', port: 'webui' },
                  initialDelaySeconds: 15,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '128Mi', cpu: '50m' },
                  limits: { memory: '512Mi', cpu: '1' },
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

    // Tailnet-only L7 ingress (no funnel), mirroring qbittorrent/autobrr/sonarr/jellyfin.
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
