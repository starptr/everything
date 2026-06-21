local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// autobrr: download-automation tool. Watches indexer announce sources (IRC channels / RSS feeds),
// matches releases against user-defined filters, and forwards each match to a download client. That
// target is a runtime choice (autobrr config, not declared here): typically Sonarr/Radarr as an
// "arr" client -- autobrr hands Sonarr the release and Sonarr grabs it via its OWN qBittorrent
// client under tv-sonarr (Sonarr owns the category/quality/import decisions, the cleanest path for
// arr-managed content) -- or qBittorrent directly under a per-filter category autobrr sets itself.
//
// No VPN sidecar and no media volume: autobrr is NOT a torrent client -- it hands releases to
// Sonarr / qBittorrent's WebUI over ClusterIP (qBittorrent being the thing behind gluetun) and
// downloads no files itself, so like sonarr/prowlarr it needs neither the gluetun sidecar nor the
// shared mdata volume. Its only persistent state is its own /config.
//
// Storage: /config holds a SQLite DB (autobrr.db) + a config.toml that autobrr rewrites at runtime.
// SQLite over NFS is unsafe (locking/corruption), so config lives on iSCSI (RWO) -- and an RWO PVC
// means the old pod must release the volume before a new one mounts it, hence strategy: Recreate.
// WebUI exposed over the tailnet via Tailscale L7 ingress.
//
// SEEDED vs DECLARATIVE -- read before editing: autobrr's download clients, indexers, filters, and
// actions (including the qBittorrent category) are RUNTIME state in the SQLite DB, configured in the
// web UI. autobrr has no config-as-code path for them (contrast buildarr/seadexarr, which are
// declarative). This lib only DEPLOYS autobrr; it does not (cannot) seed that config. config.toml
// itself is also runtime-writable: autobrr generates it on first boot -- including a random
// sessionSecret it persists to the PVC -- so we pin nothing there and let it self-manage. We only
// override a few config.toml values via AUTOBRR__* env vars (they win over config.toml each boot),
// mirroring the SONARR__/PROWLARR__ pattern.
//
// Runs as uid/gid 1000 directly (the autobrr image is NOT a LinuxServer PUID/PGID image, so there's
// no PUID/PGID env -- the user is set via securityContext, and fsGroup makes the iSCSI mount
// group-writable so autobrr can create its DB/config under /config).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    name='autobrr',
    namespace='default',
    image=images.autobrr.fullyQualifiedImageReferencePinned,
    port=7474,                          // autobrr's WebUI/API port
    timezone='America/Los_Angeles',
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
            // autobrr runs directly as this user (not a LinuxServer image that drops from root via
            // PUID/PGID). fsGroup makes the freshly-formatted iSCSI (ext4) mount group-owned by 1000
            // so autobrr (uid 1000) can create autobrr.db / config.toml under /config.
            securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 },
            containers: [
              {
                name: name,
                image: image,
                // AUTOBRR__<KEY> env vars override config.toml on every boot (same idea as the
                // SONARR__/PROWLARR__ overrides). No AUTOBRR__SESSION_SECRET: autobrr generates one
                // on first boot and persists it to config.toml on the PVC.
                env: [
                  { name: 'TZ', value: timezone },
                  // Default bind is localhost -- must bind all interfaces so the Service reaches it.
                  { name: 'AUTOBRR__HOST', value: '0.0.0.0' },
                  { name: 'AUTOBRR__PORT', value: std.toString(port) },   // explicit; same source as containerPort/Service
                  { name: 'AUTOBRR__LOG_LEVEL', value: 'INFO' },          // autobrr defaults to DEBUG/TRACE
                  { name: 'AUTOBRR__CHECK_FOR_UPDATES', value: 'false' }, // never self-update (updates happen by rolling the image)
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                ],
                // autobrr's unauthenticated liveness endpoint (200 once the process is up) -- a safe
                // readiness signal even before first-run account setup.
                readinessProbe: {
                  httpGet: { path: '/api/healthz/liveness', port: 'webui' },
                  initialDelaySeconds: 15,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '128Mi', cpu: '50m' },   // lighter than the *arr apps
                  limits: { memory: '512Mi', cpu: '1' },
                },
              },
            ],
            volumes: [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
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

    // Tailnet-only L7 ingress (no funnel), mirroring sonarr/prowlarr/jellyfin.
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
