local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Buildarr daemon: renders a given buildarr.yml `config` object into a read-only-mounted Secret and a
// headless daemon Deployment that reconciles the *arr apps to match it. This lib owns ONLY the K8s
// plumbing; the caller owns the desired state -- it passes the full config in (see the buildarrConfig
// local in main.jsonnet), so the app-specific knowledge (which apps link to which, download clients,
// Prowlarr applications, delete_unmanaged policy) lives at the call site, not here.
//
// DECLARATIVE (read-only) config, NOT a seed. Unlike qbittorrent/openclaw -- whose apps rewrite their
// own config and so are only *seeded* once -- Buildarr never rewrites buildarr.yml. The passed-in
// config IS the source of truth: it's mounted read-only and `tk apply` fully determines it (mirrors
// ddns-updater's read-only /secret config). The mutable *arr state lives in the apps themselves;
// Buildarr just drives it to match this file.
//
// No web UI / Service / Ingress: Buildarr is a headless daemon that only needs in-cluster egress to
// the apps it manages. Run faithfully to upstream's docker-compose: the image entrypoint handles
// PUID/PGID then execs the CMD, so we set only `args` (`daemon <config>`) and leave the entrypoint
// intact, and mount the config read-only at /config exactly as the compose does.
{
  new(
    config,                             // required -> the full buildarr.yml as a Jsonnet object
    name='buildarr',
    namespace='default',
    image=images.buildarr.fullyQualifiedImageReferencePinned,
    timezone='America/Los_Angeles',
  ):: {
    local this = self,

    // buildarr.yml as an Opaque Secret (not a ConfigMap): the rendered YAML embeds the apps' API keys.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-config', namespace: namespace },
      type: 'Opaque',
      stringData: { 'buildarr.yml': std.manifestYamlDoc(config) },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // ConfigMap/Secret mounts don't roll a Deployment on their own; hashing the config into
            // the template makes an edit roll the daemon so it reconciles the new desired state.
            annotations: { 'checksum/config': std.md5(std.manifestJsonEx(config, '')) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: name,
                image: image,
                // Mirror upstream's `command: [daemon, <config>]`: set only the CMD (args) and keep
                // the image entrypoint, which applies PUID/PGID before exec'ing buildarr. `daemon`
                // reconciles once on start, then on its schedule -- so a wiped *arr DB or UI drift
                // self-heals. On first boot it may error until Sonarr/Prowlarr /ping is ready;
                // restartPolicy: Always retries until it converges.
                args: ['daemon', '/config/buildarr.yml'],
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: timezone },
                ],
                // Config mounted read-only at /config (exactly as the upstream compose does with
                // read_only: true). Buildarr's runtime scratch goes to the writable container root fs.
                volumeMounts: [
                  {
                    name: utils.assertEqualAndReturn(this.deployment.spec.template.spec.volumes[0].name, 'config'),
                    mountPath: '/config',
                    readOnly: true,
                  },
                ],
                resources: {
                  requests: { memory: '128Mi', cpu: '50m' },
                  limits: { memory: '512Mi', cpu: '500m' },
                },
              },
            ],
            volumes: [
              {
                name: 'config',
                secret: { secretName: utils.assertEqualAndReturn(this.secret.metadata.name, name + '-config') },
              },
            ],
          },
        },
      },
    },
  },
}
