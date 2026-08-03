local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Immich: self-hosted photo/video backup + management. Instantiated here as a DEDICATED instance for
// band-practice media -- its own database and its own library volume, sharing nothing with the
// anime/*arr media stack (jellyfin/sonarr/shoko/...). It is this repo's first multi-datastore app, so
// unlike the single-container media libs it hand-writes THREE workloads plus their wiring:
//   * postgres  -- the metadata DB. MUST be immich's bespoke image (ghcr.io/immich-app/postgres): it
//                  bundles the VectorChord + pgvecto.rs vector extensions Immich requires for smart
//                  search / embeddings. A stock Postgres image does NOT work.
//   * redis     -- the background-job queue (Valkey, a drop-in Redis). It's a rebuildable queue, not a
//                  system of record: Immich re-queues on restart, so it runs on an ephemeral emptyDir
//                  (no PVC). Losing it costs at most in-flight jobs, which re-enqueue on the next scan.
//   * server    -- the API + web UI + background workers (single immich-server container).
//
// ---- Storage: DB on iSCSI (RWO), library on NFS (RWX) ----
// A database is UNSAFE on the NFS class (locking/corruption over NFS), so the Postgres data dir lives
// on a dedicated iSCSI RWO PVC -- same rule the *arr/jellyfin/suwayomi config PVCs follow. The bulk
// photo/video library is a large multi-file store that wants the NFS RWX class, on its OWN PVC (NOT
// the shared `mdata` volume: band media is unrelated to the downloads<->library hardlink tree, so it
// gets an isolated volume like samba's data PVC). RWO on the DB means the old pod must release the
// volume before a new one mounts it -> strategy: Recreate on Postgres; the server is also Recreate so
// two pods never write the one NFS library dir during a roll.
//
// ---- Postgres on a fresh iSCSI ext4 PVC: two k8s-only adaptations vs upstream's compose ----
// Immich's compose bind-mounts a host dir straight at /var/lib/postgresql/data with no PGDATA. That
// works for a bind mount but NOT for a freshly provisioned iSCSI ext4 PVC, which mounts with a
// `lost+found` at its root -- and initdb refuses a non-empty PGDATA. So we set
// PGDATA=<dataMount>/pgdata (a clean subdir the postgres entrypoint creates + owns) and mount the PVC
// one level up. We also recreate the compose's `shm_size: 128mb` via an in-memory emptyDir at
// /dev/shm (k8s defaults /dev/shm to a cramped 64Mi, which Postgres can exhaust). No `command`
// override is needed: the VectorChord image self-configures shared_preload_libraries.
//
// ---- Ownership on the root-squashed NFS library ----
// immich-server runs as root (uid 0). The democratic-csi NFS class root-squashes root -> nobody and
// provisions each dataset 0777, so a root->nobody server can populate the library dir without any
// chown init container (chown would EPERM under root-squash anyway; it isn't needed here because the
// 0777 root is already world-writable). Contrast suwayomi, whose non-root image needed an init chown
// on its iSCSI (non-squashed) config PVC.
//
// ---- Config / secrets ----
// Immich stores all its config in the DB (set up interactively in the web UI on first run), so this
// lib carries no config-as-code -- only the DB password, from sops. That one secret is the single
// source read by BOTH Postgres (POSTGRES_PASSWORD) and the server (DB_PASSWORD) via secretKeyRef, so
// it never appears inline in any Deployment manifest.
//
// ---- Exposure ----
// Always a tailnet-only L7 ingress (private). OPTIONALLY also a public HTTPS path: pass publicHostname
// + issuerName to additionally emit a cert-manager Certificate (Let's Encrypt via the shared Cloudflare
// DNS-01 ClusterIssuer) and a Traefik `websecure` Ingress, reached at https://<publicHostname>. Same
// public-HTTPS pattern as lib/andref-ipfs-depot.libsonnet; the DNS record lives in eight/.
{
  new(
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    dbPassword,                         // required, sops-backed -> shared by Postgres + the server
    name='immich',
    namespace='default',
    serverImage=images["immich-server"].fullyQualifiedImageReferencePinned,
    dbImage=images["immich-postgres"].fullyQualifiedImageReferencePinned,
    redisImage=images.valkey.fullyQualifiedImageReferencePinned,
    port=2283,                          // immich-server HTTP API/WebUI port
    timezone='America/Los_Angeles',
    dbUser='immich',
    dbName='immich',
    // VectorChord tunes its index build for the storage tier. 'HDD' relaxes the SSD assumption and is
    // safe on SSD too (just conservative); flip to 'SSD' if methanol's rpool is flash-backed.
    dbStorageType='HDD',
    dbStorageClassName='my-custom-zfs-generic-iscsi',       // RWO iSCSI; a DB must NOT be on NFS
    dbStorageSize='20Gi',
    libraryStorageClassName='my-custom-zfs-generic-nfs-csi', // RWX NFS for the bulk photo/video library
    libraryStorageSize='500Gi',
    dbMountPath='/var/lib/postgresql/data',   // PVC mount; PGDATA is a subdir beneath it (see header)
    libraryMountPath='/data',                 // immich-server's in-container media root (compose maps UPLOAD_LOCATION here)
    // Optional public HTTPS exposure (in addition to the tailnet ingress) -- see header.
    publicHostname=null,                      // e.g. 'cd-jams.andref.app'; null -> tailnet-only
    issuerName=null,                          // required when publicHostname is set: cert-manager ClusterIssuer name
  ):: {
    local this = self,

    // Public exposure needs an issuer to obtain its cert from.
    assert publicHostname == null || issuerName != null :
      name + ': publicHostname requires issuerName (the cert-manager ClusterIssuer)',
    local dbName_ = name + '-db',
    local redisName = name + '-redis',

    // DB password from sops, read by both Postgres and the server via secretKeyRef (never inlined).
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: { dbPassword: dbPassword },
    },

    // Postgres data: iSCSI RWO (a DB must not live on NFS).
    dbPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: dbName_, namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: dbStorageClassName,
        resources: { requests: { storage: dbStorageSize } },
      },
    },

    // Photo/video library: dedicated NFS RWX (its own volume, not the shared mdata PVC).
    libraryPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-library', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteMany'],
        storageClassName: libraryStorageClassName,
        resources: { requests: { storage: libraryStorageSize } },
      },
    },

    // ---- Postgres (VectorChord/pgvecto.rs) ----
    dbDeployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: dbName_, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // RWO data PVC: old pod must release before new mounts
        selector: { matchLabels: { app: dbName_ } },
        template: {
          metadata: { labels: {} + this.dbDeployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: 'postgres',
                image: dbImage,
                env: [
                  { name: 'POSTGRES_USER', value: dbUser },
                  { name: 'POSTGRES_DB', value: dbName },
                  { name: 'POSTGRES_PASSWORD', valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'dbPassword' } } },
                  { name: 'POSTGRES_INITDB_ARGS', value: '--data-checksums' },
                  // PGDATA in a clean subdir so initdb doesn't trip over the ext4 lost+found at the
                  // PVC root (see header). The postgres entrypoint creates + chowns it.
                  { name: 'PGDATA', value: dbMountPath + '/pgdata' },
                ],
                ports: [{ name: 'postgres', containerPort: 5432 }],
                volumeMounts: [
                  { name: 'data', mountPath: dbMountPath },
                  { name: 'shm', mountPath: '/dev/shm' },   // recreates the compose's shm_size: 128mb
                ],
                readinessProbe: {
                  exec: { command: ['pg_isready', '-U', dbUser, '-d', dbName] },
                  initialDelaySeconds: 10,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '250m' },
                  limits: { memory: '2Gi', cpu: '2' },
                },
              },
            ],
            volumes: [
              { name: 'data', persistentVolumeClaim: { claimName: this.dbPvc.metadata.name } },
              { name: 'shm', emptyDir: { medium: 'Memory', sizeLimit: '128Mi' } },
            ],
          },
        },
      },
    },

    dbService: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: dbName_, namespace: namespace },
      spec: {
        selector: {} + this.dbDeployment.spec.template.metadata.labels,
        ports: [{
          name: 'postgres',
          port: 5432,
          targetPort: utils.assertEqualAndReturn(this.dbDeployment.spec.template.spec.containers[0].ports[0].name, 'postgres'),
        }],
        type: 'ClusterIP',
      },
    },

    // ---- Redis / Valkey (ephemeral job queue) ----
    redisDeployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: redisName, namespace: namespace },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: redisName } },
        template: {
          metadata: { labels: {} + this.redisDeployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: 'redis',
                image: redisImage,
                ports: [{ name: 'redis', containerPort: 6379 }],
                // No PVC: the queue is rebuildable state, so it lives on the pod's ephemeral rootfs.
                readinessProbe: {
                  tcpSocket: { port: 'redis' },
                  initialDelaySeconds: 5,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '32Mi', cpu: '25m' },
                  limits: { memory: '256Mi', cpu: '500m' },
                },
              },
            ],
          },
        },
      },
    },

    redisService: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: redisName, namespace: namespace },
      spec: {
        selector: {} + this.redisDeployment.spec.template.metadata.labels,
        ports: [{
          name: 'redis',
          port: 6379,
          targetPort: utils.assertEqualAndReturn(this.redisDeployment.spec.template.spec.containers[0].ports[0].name, 'redis'),
        }],
        type: 'ClusterIP',
      },
    },

    // ---- immich-server (API + web + workers) ----
    serverDeployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // singleton over one NFS library dir: avoid two writers during a roll
        selector: { matchLabels: { app: name } },
        template: {
          metadata: { labels: {} + this.serverDeployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: 'immich-server',
                image: serverImage,
                env: [
                  // DB + Redis connection. Our Service names differ from immich's compose defaults
                  // (database/redis), so set the hostnames explicitly. The password is the same sops
                  // secret Postgres reads.
                  { name: 'DB_HOSTNAME', value: this.dbService.metadata.name },
                  { name: 'DB_PORT', value: '5432' },
                  { name: 'DB_USERNAME', value: dbUser },
                  { name: 'DB_DATABASE_NAME', value: dbName },
                  { name: 'DB_PASSWORD', valueFrom: { secretKeyRef: { name: this.secret.metadata.name, key: 'dbPassword' } } },
                  { name: 'DB_STORAGE_TYPE', value: dbStorageType },
                  { name: 'REDIS_HOSTNAME', value: this.redisService.metadata.name },
                  { name: 'REDIS_PORT', value: '6379' },
                  { name: 'TZ', value: timezone },
                ],
                ports: [{ name: 'webui', containerPort: port }],
                volumeMounts: [
                  // The library PVC IS the media root (immich-server defaults its media location to
                  // /data, which is where upstream's compose maps UPLOAD_LOCATION).
                  { name: 'library', mountPath: libraryMountPath },
                ],
                // /api/server/ping is Immich's unauthenticated liveness endpoint ({"res":"pong"}).
                // Generous initialDelay: first boot runs DB migrations (incl. creating the vector
                // extension), which can take a while. Readiness only (no liveness) so a slow first
                // migration can't crash-loop the pod.
                readinessProbe: {
                  httpGet: { path: '/api/server/ping', port: 'webui' },
                  initialDelaySeconds: 30,
                  periodSeconds: 15,
                  failureThreshold: 10,
                },
                resources: {
                  requests: { memory: '512Mi', cpu: '250m' },
                  limits: { memory: '4Gi', cpu: '2' },
                },
              },
            ],
            volumes: [
              { name: 'library', persistentVolumeClaim: { claimName: this.libraryPvc.metadata.name } },
            ],
          },
        },
      },
    },

    serverService: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: name, namespace: namespace },
      spec: {
        selector: {} + this.serverDeployment.spec.template.metadata.labels,
        ports: [{
          name: 'webui',
          port: port,
          targetPort: utils.assertEqualAndReturn(this.serverDeployment.spec.template.spec.containers[0].ports[0].name, 'webui'),
        }],
        type: 'ClusterIP',
      },
    },

    // Tailnet-only L7 ingress (no funnel), mirroring jellyfin/suwayomi/shoko.
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
                  name: this.serverService.metadata.name,
                  port: { number: utils.assertEqualAndReturn(this.serverService.spec.ports[0].port, port) },
                },
              },
            }],
          },
        }],
      },
    },

    // Public HTTPS (optional): cert-manager issues an LE cert (Cloudflare DNS-01 -- no inbound
    // reachability needed to issue) into <name>-tls, which the hostNetwork Traefik serves. Same
    // namespace as the ingress so Traefik can read the Secret.
    [if publicHostname != null then 'certificate']: {
      apiVersion: 'cert-manager.io/v1',
      kind: 'Certificate',
      metadata: { name: name + '-tls', namespace: namespace },
      spec: {
        secretName: name + '-tls',
        dnsNames: [publicHostname],
        issuerRef: { name: issuerName, kind: 'ClusterIssuer' },
      },
    },

    // Public L7 ingress on the hostNetwork Traefik (methanol :443), websecure-only. Reached at
    // https://<publicHostname> because that host CNAMEs to carless-drivers-ddns (home IP) and the
    // router already forwards WAN 443 to methanol. Distinct name from the tailnet ingress above.
    [if publicHostname != null then 'publicIngress']: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name + '-public',
        namespace: namespace,
        annotations: { 'traefik.ingress.kubernetes.io/router.entrypoints': 'websecure' },
      },
      spec: {
        ingressClassName: 'traefik',
        tls: [{
          hosts: [publicHostname],
          secretName: utils.assertEqualAndReturn(this.certificate.spec.secretName, name + '-tls'),
        }],
        rules: [{
          host: publicHostname,
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: this.serverService.metadata.name,
                  port: { number: utils.assertEqualAndReturn(this.serverService.spec.ports[0].port, port) },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
