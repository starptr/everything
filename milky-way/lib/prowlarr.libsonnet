local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Prowlarr (LinuxServer.io): indexer manager. Configure indexers (trackers/usenet) once here and
// Prowlarr pushes them to the *arr apps (Sonarr now, Radarr later) over HTTP + API key. It manages
// no media files, so -- unlike Sonarr -- it mounts NO shared media volume; the only persistent
// state is its own /config.
//
// No VPN sidecar (and no media volume). /config holds a SQLite DB + config.xml rewritten at
// runtime; SQLite over NFS is unsafe, so config lives on iSCSI (RWO), and an RWO PVC forces
// strategy: Recreate (old pod releases before new mounts). WebUI exposed over the tailnet via
// Tailscale L7 ingress.
//
// Config pinned declaratively via servarr env overrides (PROWLARR__<SECTION>__<KEY>, double
// underscore; they win over config.xml every boot): the API key (from a Secret, so it's stable
// rather than the random key Prowlarr would mint on first boot), the explicit port, and the update
// settings that keep Prowlarr from EVER updating itself (mechanism=Docker disables the in-app updater).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    apiKey,                             // required -> Prowlarr API key (from sops; surfaced via the Secret below)
    name='prowlarr',
    namespace='default',
    image=images.prowlarr.fullyQualifiedImageReferencePinned,
    port=9696,                          // Prowlarr's WebUI/API port
    timezone='America/Los_Angeles',
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='5Gi',
  ):: {
    local this = self,

    // API key as an Opaque Secret (value from the sops-backed `apiKey` param). Mirrors the
    // openclaw/gluetun stringData idiom; the env var below reads it via secretKeyRef.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: { apikey: apiKey },
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
            containers: [
              {
                name: name,
                image: image,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: timezone },
                  // Servarr config overrides (PROWLARR__<SECTION>__<KEY>). The PROWLARR__ prefix is the
                  // application's, independent of the `name` param; these override config.xml each boot.
                  { name: 'PROWLARR__SERVER__PORT', value: std.toString(port) },   // explicit; same source as containerPort/Service
                  { name: 'PROWLARR__UPDATE__MECHANISM', value: 'Docker' },        // container-managed -> disables Prowlarr's in-app updater
                  { name: 'PROWLARR__UPDATE__AUTOMATICALLY', value: 'false' },     // never auto-apply updates
                  // Auth handled at the network edge (Tailscale ingress is the boundary, same model as
                  // qbittorrent), so the app itself does no login -> 'External'. This is also what lets
                  // Buildarr manage Prowlarr: its bundled prowlarr plugin only accepts basic/forms/
                  // external and CRASHES reading the servarr default 'none' (Sonarr's newer plugin
                  // tolerates 'none', so Sonarr needs no equivalent override).
                  { name: 'PROWLARR__AUTH__METHOD', value: 'External' },
                  // API key read from the Secret above -> stable across reboots / config resets.
                  {
                    name: 'PROWLARR__AUTH__APIKEY',
                    valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'apikey' } },
                  },
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                ],
                // /ping is Prowlarr's unauthenticated health endpoint -- safe readiness signal even
                // before first-run setup.
                readinessProbe: {
                  httpGet: { path: '/ping', port: 'webui' },
                  initialDelaySeconds: 15,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '1Gi', cpu: '1' },
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

    // Tailnet-only L7 ingress (no funnel), mirroring qbittorrent/openclaw.
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
