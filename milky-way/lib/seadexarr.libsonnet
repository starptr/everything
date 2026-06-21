local images = import 'milky-way/lib/images.libsonnet';

// SeaDexArr (bbtufty/seadexarr): a scheduled BACKGROUND daemon -- it reads your Sonarr (and, when
// present, Radarr) library, picks the SeaDex-curated "best" release per entry, and adds that torrent
// straight into qBittorrent under a category Sonarr watches, so Sonarr imports it. It runs a loop
// (`run scheduled`, sleeping SCHEDULE_TIME hours between passes), not a web server, so this lib emits
// NO Service and NO Ingress -- there is nothing to expose.
//
// CONFIG_DIR (=/config, baked into the image) must be WRITABLE: on boot the app's verify_config()
// opens /config/config.yml with "w+" (it re-validates/normalizes the file against its bundled
// template), and it also writes a regenerable cache.json there. A read-only config mount makes both
// the Sonarr and Radarr modules crash with "Read-only file system: '/config/config.yml'".
//
// So /config is a writable emptyDir, and the rendered config is SEEDED into it from a read-only
// Secret by an init container that copies /seed/config.yml -> /config/config.yml on every start.
// Because the emptyDir starts empty on each (re)start, the seed is re-applied every boot, so the
// Jsonnet-rendered config still wins each time (the same "our declaration re-applied every boot"
// contract as the servarr env overrides) -- the app's in-place rewrites to its working copy are
// transient and discarded on the next roll. A config change rolls the pod via the checksum/config
// annotation below, which re-seeds the new content. The Secret holds the API keys + Discord webhook,
// so it's a Secret, not a ConfigMap. Losing the emptyDir on restart just re-warms cache.json from
// SeaDex/AniList -- not state worth persisting.
//
// The image is plain python (no s6/LinuxServer layer): it runs as ROOT (no PUID/PGID), and its
// ENTRYPOINT is `seadexarr` with NO default CMD -- so we must pass `run scheduled` ourselves or it
// just prints help and crashloops.
{
  // Mirror of seadexarr/modules/config_sample.yml defaults. The caller passes only the meaningful
  // keys via `config`; merging over this set means every key the app reads is still emitted (so a
  // loader that indexes a key directly can't KeyError on an advanced one the caller left unset).
  local defaultConfig = {
    // Sonarr
    sonarr_url: null,
    sonarr_api_key: null,
    sonarr_ignore_unmonitored: false,
    ignore_movies_in_radarr: false,
    // Radarr
    radarr_url: null,
    radarr_api_key: null,
    radarr_ignore_unmonitored: false,
    // qBittorrent
    qbit_info: { host: null, username: null, password: null },
    // Categories / tags for added torrents
    sonarr_torrent_category: null,
    radarr_torrent_category: null,
    torrent_tags: null,
    // Behaviour
    ignore_seadex_update_times: false,
    use_torrent_hash_to_filter: false,
    max_torrents_to_add: null,
    discord_url: null,
    // SeaDex filters
    public_only: true,
    prefer_dual_audio: true,
    want_best: true,
    ignore_tags: null,
    trackers: null,
    // Advanced
    sleep_time: 2,
    cache_time: 1,
    interactive: false,
    anime_mappings: null,
    anidb_mappings: null,
    anibridge_mappings: null,
    log_level: 'INFO',
  },

  new(
    config,                  // overrides shallow-merged over defaultConfig; rendered to a read-only Secret
    name='seadexarr',
    namespace='default',
    image=images.seadexarr.fullyQualifiedImageReferencePinned,
    scheduleHours=6,         // SCHEDULE_TIME: hours the scheduled loop sleeps between passes
    timezone='America/Los_Angeles',
  ):: {
    local this = self,
    // One source of truth for the rendered config.yml: feeds both the Secret and the pod-template
    // checksum below.
    local mergedConfigYaml = std.manifestYamlDoc(defaultConfig + config),

    // config.yml carries the Sonarr/qBittorrent API keys and the Discord webhook -> Secret, not
    // ConfigMap. YAML is the format the app's loader (PyYAML) expects.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-config', namespace: namespace },
      type: 'Opaque',
      stringData: { 'config.yml': mergedConfigYaml },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        // It mutates EXTERNAL state (adds torrents to qBittorrent); two instances overlapping during
        // a rolling update could double-add. Recreate keeps at most one alive.
        strategy: { type: 'Recreate' },
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // A subPath Secret mount does NOT live-update, and editing a Secret doesn't roll a
            // Deployment on its own. Hashing the rendered config into the pod template makes a config
            // change roll the pod so the new config.yml actually takes effect.
            annotations: { 'checksum/config': std.md5(mergedConfigYaml) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // Seed the rendered config.yml from the read-only Secret into the writable /config emptyDir
            // before the app starts (the app then reads+rewrites it in place). `command` overrides the
            // image's `seadexarr` entrypoint; `cp` exists in the python base image, so no extra image.
            initContainers: [
              {
                name: 'seed-config',
                image: image,
                command: ['cp', '/seed/config.yml', '/config/config.yml'],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'config-seed', mountPath: '/seed', readOnly: true },
                ],
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                args: ['run', 'scheduled'],   // ENTRYPOINT `seadexarr` has no default CMD
                env: [
                  { name: 'SCHEDULE_TIME', value: std.toString(scheduleHours) },
                  { name: 'TZ', value: timezone },
                  // CONFIG_DIR=/config is already baked into the image; config.yml + cache.json live there.
                ],
                volumeMounts: [
                  // Writable /config: holds the seeded config.yml (app rewrites it) and cache.json.
                  { name: 'config', mountPath: '/config' },
                ],
                resources: {
                  requests: { memory: '128Mi', cpu: '50m' },
                  limits: { memory: '512Mi', cpu: '1' },
                },
              },
            ],
            volumes: [
              { name: 'config', emptyDir: {} },
              {
                name: 'config-seed',
                secret: {
                  secretName: this.secret.metadata.name,
                  items: [{ key: 'config.yml', path: 'config.yml' }],
                },
              },
            ],
          },
        },
      },
    },
  },
}
