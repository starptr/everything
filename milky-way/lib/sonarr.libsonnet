local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Sonarr (LinuxServer.io): monitors/grabs TV episodes, hands torrents to qbittorrent, then imports
// completed downloads by hardlinking them out of the qbittorrent save dir into a library tree.
//
// No VPN sidecar (Sonarr is not a torrent client -- it talks to qbittorrent's WebUI, which is the
// thing behind gluetun) and no config seed (Sonarr writes config.xml itself on first boot, so
// there's nothing to seed -- contrast qbittorrent, which seeds qBittorrent.conf only-if-empty).
//
// Storage: /config holds a SQLite DB + config.xml that Sonarr rewrites at runtime. SQLite over NFS
// is unsafe (locking/corruption), so config lives on iSCSI (RWO) -- and an RWO PVC means the old
// pod must release the volume before a new one mounts it, hence strategy: Recreate. Media lives on
// the SHARED `mdata` RWX-NFS PVC (the same one qbittorrent mounts), mounted here at the same path
// so that downloads (<mediaMountPath>/downloads/qbittorrent) and the library tree
// (<mediaMountPath>/library/{Animations,TV Shows}, set as Sonarr root folders via buildarr) are
// one filesystem -- hardlinks and atomic moves require that.
//
// Config that we pin declaratively via servarr env overrides (SONARR__<SECTION>__<KEY>, double
// underscore; they win over config.xml on every boot): the API key (from a Secret, so it's stable
// and Prowlarr's link to Sonarr is reproducible -- not the random key Sonarr would otherwise mint
// on first boot), the explicit port, and the update settings that keep Sonarr from EVER updating
// itself (mechanism=Docker -> the in-app updater is disabled; updates happen by rolling the image).
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    mediaVolumeClaimName,               // required -> external shared RWX PVC (the `mdata` PVC in main.jsonnet)
    apiKey,                             // required -> Sonarr API key (from sops; surfaced via the Secret below)
    name='sonarr',
    namespace='default',
    image=images.sonarr.fullyQualifiedImageReferencePinned,
    port=8989,                          // Sonarr's WebUI/API port
    timezone='America/Los_Angeles',
    configStorageClassName='my-custom-zfs-generic-iscsi',   // RWO; SQLite must not be on NFS
    configStorageSize='5Gi',
    mediaMountPath='/data',             // whole shared volume mounted here (matches qbittorrent's /data)
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
                  // Servarr config overrides (SONARR__<SECTION>__<KEY>). The SONARR__ prefix is the
                  // application's, independent of the `name` param; these override config.xml each boot.
                  { name: 'SONARR__SERVER__PORT', value: std.toString(port) },    // explicit; same source as containerPort/Service
                  { name: 'SONARR__UPDATE__MECHANISM', value: 'Docker' },         // container-managed -> disables Sonarr's in-app updater
                  { name: 'SONARR__UPDATE__AUTOMATICALLY', value: 'false' },      // never auto-apply updates
                  // API key read from the Secret above -> stable across reboots / config resets.
                  {
                    name: 'SONARR__AUTH__APIKEY',
                    valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'apikey' } },
                  },
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'media', mountPath: mediaMountPath },
                ],
                // /ping is Sonarr's unauthenticated health endpoint (returns 200 regardless of the
                // login/auth config), so it's a safe readiness signal even before first-run setup.
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
