local zfsIscsiDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-iscsi-democratic-csi-driver-config.jsonnet';
local zfsNfsDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-nfs-democratic-csi-driver-config.jsonnet';
local charts = import 'milky-way/charts.jsonnet';
local httpEcho = import 'milky-way/lib/http-echo.libsonnet';
local exampleZfsGenericIscsi = import 'milky-way/lib/example-zfs-generic-iscsi.libsonnet';
local kataRuntimeClass = import 'milky-way/lib/kata-runtime-class.libsonnet';
local kataMicrovmTest = import 'milky-way/lib/kata-microvm-test.libsonnet';
local calibreWebAuto = import 'milky-way/lib/calibre-web-automated.libsonnet';
local ddnsUpdater = import 'milky-way/lib/ddns-updater.libsonnet';
local traefik = import 'milky-way/lib/traefik.libsonnet';
local tailscaleOperator = import 'milky-way/lib/tailscale-operator.libsonnet';
local testTailscaleIngress = import 'milky-way/lib/test-tailscale-operator-ingress.libsonnet';
local testTailscaleL3 = import 'milky-way/lib/test-tailscale-operator-network-L3.libsonnet';
local openclaw = import 'milky-way/lib/openclaw.libsonnet';
local qbittorrent = import 'milky-way/lib/qbittorrent.libsonnet';
local vpnProxy = import 'milky-way/lib/vpn-proxy.libsonnet';
local sonarr = import 'milky-way/lib/sonarr.libsonnet';
local prowlarr = import 'milky-way/lib/prowlarr.libsonnet';
local jellyfin = import 'milky-way/lib/jellyfin.libsonnet';
local autobrr = import 'milky-way/lib/autobrr.libsonnet';
local buildarr = import 'milky-way/lib/buildarr.libsonnet';
local seadexarr = import 'milky-way/lib/seadexarr.libsonnet';
local utils = import 'milky-way/lib/utils.libsonnet';
local wgConf = import 'milky-way/lib/wireguard-conf.libsonnet';
local sftp = import 'milky-way/lib/sftp.libsonnet';
local grandCentral = import 'milky-way/lib/grand-central.libsonnet';
local gluetunLeakTest = import 'milky-way/lib/gluetun-leak-test.libsonnet';
local testExampleWhaleImageDigest = import 'milky-way/lib/test-example-whale-image-digest.libsonnet';
local secrets = import 'milky-way/secrets/k8s-secret-values.jsonnet';
{
  local this = self,
  democraticCsiNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "democratic-csi",
    },
  },
  zfsIscsiDriver: charts.zfs_iscsi,
  zfsNfsDriver: charts.zfs_nfs,
  "my-custom-zfs-iscsi-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-iscsi-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsIscsiDriverConfig)),
    },
  },
  "my-custom-zfs-nfs-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-nfs-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsNfsDriverConfig)),
    },
  },
  testingNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "test-k8s",
    },
  },
  httpEcho: httpEcho.new(),
  exampleZfsGenericIscsi: exampleZfsGenericIscsi.new(storageClassName="my-custom-zfs-generic-iscsi"),
  // TODO: rename lib
  exampleZfsNfs: exampleZfsGenericIscsi.new(
    storageClassName="my-custom-zfs-generic-nfs-csi",
    name="nfs-test",
  ),
  kataRuntimeClass: kataRuntimeClass.runtimeClass,
  kataMicrovmTest: kataMicrovmTest.new(),
  testExampleWhaleImageDigest: testExampleWhaleImageDigest.new(),
  calibreWebAuto: calibreWebAuto.new(domain="cwa-methanol.local"),

  ddnsUpdater: ddnsUpdater.new(
    config={
      settings: [
        {
          provider: "cloudflare",
          zone_identifier: secrets.ddnsUpdater.cloudflare.zone_identifier,
          domain: "carless-drivers-cfproxied-ddns.andref.app",
          ttl: 1,
          token: secrets.ddnsUpdater.cloudflare.token,
          ip_version: "ipv4",
          # Proxy gives the domain an SSL cert for free
          proxied: true,
        },
        {
          provider: "cloudflare",
          zone_identifier: secrets.ddnsUpdater.cloudflare.zone_identifier,
          domain: "carless-drivers-ddns.andref.app",
          ttl: 1,
          token: secrets.ddnsUpdater.cloudflare.token,
          ip_version: "ipv4",
          # Non-proxied: resolves directly to the home IP (no Cloudflare SSL/proxy).
          proxied: false,
        },
      ],
    },
    webuiEndpointDomain="carless-drivers-cfproxied-ddns.andref.app",
  ),

  tailscaleOperator: tailscaleOperator.new(
    client_id = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_id,
    client_secret = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_secret,
    operatorTags = 'tag:k8s-orion-system-operator',
    proxyTags = 'tag:k8s-orion-system',
  ),

  testTailscaleIngress: testTailscaleIngress.new(tailscaleHostname = "test-ts-ingress"),

  testTailscaleL3: testTailscaleL3.new(tailscaleHostname = "test-ts-l3"),

  openclaw: openclaw.new(
    gatewayToken = secrets.openclaw.OPENCLAW_GATEWAY_TOKEN,
    geminiApiKey = secrets.openclaw.GEMINI_API_KEY,
    tailscaleHostname = "openclaw",
    tailnet = "tail4c9a",
  ),

  // Shared media library volume. Apps mount this whole PVC and hardlink between subdirs
  // (e.g. qbittorrent writes downloads/qbittorrent/, *arr apps hardlink into a library/ tree).
  // Hardlinks require a single filesystem, so everything that shares files mounts this one PVC.
  mdataPvc: {
    apiVersion: "v1",
    kind: "PersistentVolumeClaim",
    metadata: { name: "mdata", namespace: "default" },
    spec: {
      accessModes: ["ReadWriteMany"],
      storageClassName: "my-custom-zfs-generic-nfs-csi",
      resources: { requests: { storage: "1Ti" } },
    },
  },

  // Headless qbittorrent whose traffic is forced through a ProtonVPN/WireGuard tunnel by an embedded
  // gluetun sidecar killswitch (lib/gluetun.libsonnet), with NAT-PMP port forwarding so it's
  // connectable for inbound peers (ProtonVPN supports PF; NordVPN does not). WebUI via Tailscale L7
  // ingress. Downloads land in downloads/qbittorrent/ on the shared mdata volume (mounted at /data).
  // The WireGuard key is read straight from the sops-managed ProtonVPN .conf (only Interface.
  // PrivateKey is used; gluetun selects its own PF-capable P2P server).
  qbittorrent: qbittorrent.new(
    wireguardPrivateKey = wgConf.privateKeyOf(importstr 'milky-way/secrets/qbt-gluetun.conf'),
    tailscaleHostname = "qbittorrent",
    vpnProvider = "protonvpn",
    serverCountries = "United States",
    volumeClaimName = this.mdataPvc.metadata.name,
    volumeMountPath = "/data",
    downloadsSubdir = "downloads/qbittorrent",
  ),

  // vpn-proxy: a VPN-egress HTTP forward proxy. gluetun's built-in HTTP proxy (:8888) forwards every
  // request through its own ProtonVPN/WireGuard killswitched tunnel -- gluetun is both the tunnel and
  // the proxy, so the pod is gluetun-only (no app container). It runs on a SEPARATE WireGuard key from
  // qbittorrent (the same key on two concurrent ProtonVPN sessions flaps). No web UI -- it's reached
  // in-cluster only, at http://vpn-proxy.default.svc.cluster.local:8888. autobrr points its IRC proxy
  // there (configured in autobrr's UI; that's runtime DB state, not config-as-code here).
  vpnProxy: vpnProxy.new(
    wireguardPrivateKey = wgConf.privateKeyOf(importstr 'milky-way/secrets/gluetun-vpn-proxy.conf'),
    vpnProvider = "protonvpn",
    serverCountries = "United States",
  ),

  // Sonarr: monitors/grabs TV episodes, hands torrents to qbittorrent
  // (qbittorrent.default.svc.cluster.local:8080), then imports completed downloads by hardlinking
  // them out of /data/downloads/qbittorrent into a library tree (/data/library/Animations and
  // '/data/library/TV Shows', set as Sonarr root folders via buildarrConfig below) on the
  // SHARED mdata volume -- same PVC, same /data mount path as qbittorrent, so hardlinks/atomic
  // moves stay on one filesystem. WebUI via Tailscale L7 ingress; SQLite config on its own iSCSI
  // RWO PVC. The download-client/indexer links are entered in the UI post-deploy (they need API
  // keys each app generates on first boot).
  sonarr: sonarr.new(
    apiKey = secrets.sonarr.apiKey,
    tailscaleHostname = "sonarr",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // Prowlarr: indexer manager. No media volume -- it pushes indexer configs to Sonarr
  // (sonarr.default.svc.cluster.local:8989, and later Radarr) over ClusterIP DNS. WebUI via
  // Tailscale L7 ingress; SQLite config on its own iSCSI RWO PVC.
  prowlarr: prowlarr.new(
    apiKey = secrets.prowlarr.apiKey,
    tailscaleHostname = "prowlarr",
  ),

  // Jellyfin: media server for the library the *arr stack builds on the shared mdata volume.
  // Reads /data/library/... (same PVC, same /data mount as sonarr/qbittorrent), so it serves the
  // exact tree Sonarr hardlinks completed downloads into. SQLite config + metadata cache on its
  // own iSCSI RWO PVC. WebUI via Tailscale L7 ingress; first-run setup is interactive (no API key
  // to pin, so no Secret / buildarr wiring).
  jellyfin: jellyfin.new(
    tailscaleHostname = "jellyfin",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // autobrr: download automation. Watches indexer announces (IRC/RSS), matches releases against
  // filters, and forwards each match to a download client -- typically Sonarr as an "arr" client
  // (Sonarr then grabs via its own qBittorrent client under tv-sonarr, owning the category), or
  // qBittorrent directly under a per-filter category. No media volume / no VPN sidecar: it hands
  // releases to Sonarr / qBittorrent over ClusterIP, it isn't a torrent client itself. The download
  // clients + indexers + filters + categories are runtime UI/DB state -- autobrr has no
  // config-as-code for them, so they are NOT declared here (contrast buildarr above). SQLite config
  // (incl. a self-generated sessionSecret) on its own iSCSI RWO PVC; WebUI via Tailscale L7 ingress.
  autobrr: autobrr.new(
    tailscaleHostname = "autobrr",
  ),

  // Buildarr: declaratively asserts the inter-app links the *arr apps store in SQLite (and which the
  // SONARR__/PROWLARR__ env overrides can't reach) -- Sonarr's qBittorrent download client and
  // Prowlarr's Sonarr application (which auto-syncs Prowlarr's indexers into Sonarr). Plumbing only:
  // the trackers themselves stay manual in Prowlarr, so `delete_unmanaged: false` is set on every
  // managed section AND as a plugin-global default -- Buildarr would otherwise be free to delete
  // resources it doesn't manage. Buildarr has no single master switch for this (it's per-section), so
  // the global blocks cover only the sections we manage; a future edit that manages a NEW section must
  // add its own explicit `delete_unmanaged: false`. NEVER flip any of these to true.
  //
  // This desired-state config is owned HERE (the lib is just the daemon plumbing). Host/port for each
  // app come from its Service (the source of truth): the FQDN via utils.domainOfService, and the
  // webui port as ports[0] after asserting ports[0] really is the webui entry (qbittorrent's Service
  // also exposes gluetun-ctrl). API keys come from sops.
  local buildarrConfig =
    local sonarrOrionSystemInstanceName = 'sonarr-orion-system';
    local prowlarrOrionSystemInstanceName = 'prowlarr-orion-system';
    local httpUrl(hostname, port) = 'http://%s:%d' % [hostname, port];
    {
      buildarr: {
        // Buildarr rolls via the Deployment's checksum/config annotation, not in-place file watch.
        watch_config: false,
        // Reconcile hourly on the hour (in addition to the once-on-pod-start run), so UI/DB drift
        // self-heals within the hour instead of waiting for buildarr's default single 03:00 run.
        // `update_times` are fixed HH:MM clock times -- buildarr has no interval syntax -- so an
        // hourly cadence is the 24 on-the-hour entries, generated rather than hand-listed.
        // `update_days` defaults to all 7 days. For an immediate reconcile out-of-band, SIGHUP the
        // daemon (PID 1): `kubectl --context methanol exec deploy/buildarr -- kill -HUP 1`.
        update_times: ['%02d:00' % h for h in std.range(0, 23)],
      },
      sonarr: {
        // GLOBAL defaults for all sonarr instances (current + future). MUST stay false -- never
        // clobber download clients (or root folders) added by hand in Sonarr's UI.
        settings: {
          download_clients: { delete_unmanaged: false },
          media_management: { delete_unmanaged_root_folders: false },
        },
        instances: {
          [sonarrOrionSystemInstanceName]: {
            hostname: utils.domainOfService(this.sonarr.service),
            port: utils.associateObjectsByKey(this.sonarr.service.spec.ports, 'name')['webui'].port,
            protocol: 'http',
            api_key: secrets.sonarr.apiKey,
            settings: {
              download_clients: {
                delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                definitions: {
                  qBittorrent: {
                    type: 'qbittorrent',
                    host: utils.domainOfService(this.qbittorrent.service),
                    port: utils.associateObjectsByKey(this.qbittorrent.service.spec.ports, 'name')['webui'].port,
                    // No username/password: qBittorrent's AuthSubnetWhitelist bypasses auth for
                    // in-cluster callers (Sonarr is in the pod CIDR). See lib/qbittorrent.libsonnet.
                    category: 'tv-sonarr',  // qBittorrent category Sonarr tags its grabs with
                  },
                },
              },
              media_management: {
                // Episode naming / media-management rules, asserted declaratively so they self-heal
                // on the hourly reconcile instead of being hand-set in the UI.
                rename_episodes: true,
                replace_illegal_characters: true,
                // NOTE: Sonarr's "Colon Replacement: Smart Replace" is intentionally NOT here --
                // buildarr-sonarr 0.6.4 (pinned callum027/buildarr:0.7.8) has no colon_replacement
                // field. Set it by hand in Sonarr's UI (Settings > Media Management); Buildarr does
                // not manage it, so the manual value isn't clobbered.
                standard_episode_format: '{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Preferred Words}{Quality Full}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoCodec]}{-Release Group}',
                daily_episode_format: '{Series TitleYear} - S{season:00}E{episode:00} - {Air.Date} - {Episode CleanTitle} [{Preferred Words}{Quality Full}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoCodec]}{-Release Group}',
                anime_episode_format: '{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:117} [{Preferred Words}{Quality Full}]{[MediaInfo VideoDynamicRangeType]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}[{Mediainfo AudioCodec} {Mediainfo AudioChannels}]{MediaInfo AudioLanguages}{-Release Group}',
                series_folder_format: '{Series TitleYear} [imdb-{ImdbId}]',
                season_folder_format: 'Season {season:00}',
                specials_folder_format: 'Specials',
                multiepisode_style: 'scene',
                delete_unmanaged_root_folders: false,  // also explicit per-instance (belt & suspenders)
                // These root folders are paths INSIDE the Sonarr container -- the `mdata` PVC, which
                // Sonarr mounts at /data (matching qbittorrent so hardlinks stay on one fs). Look up
                // the media mount by name, then assert that mount is /data, so a future
                // mediaMountPath change (or a renamed mount) fails at evaluation instead of
                // silently leaving these root folders pointing where Sonarr no longer mounts (its API
                // rejects a non-existent path). The paths below stay LITERAL on purpose -- they must
                // not auto-follow an accidental mountPath change.
                local mediaMount = utils.associateObjectsByKey(
                  this.sonarr.deployment.spec.template.spec.containers[0].volumeMounts, 'name'
                )['media'],
                assert mediaMount.mountPath == '/data' :
                  'sonarr media mount must be at /data for these buildarr root_folders to resolve',
                root_folders: [
                  '/data/library/Animations',
                  '/data/library/TV Shows',
                ],
              },
            },
          },
        },
      },
      prowlarr: {
        // GLOBAL default for all prowlarr instances (current + future). MUST stay false -- never
        // clobber apps/indexers added by hand in Prowlarr's UI.
        settings: { apps: { applications: { delete_unmanaged: false } } },
        instances: {
          [prowlarrOrionSystemInstanceName]: {
            hostname: utils.domainOfService(this.prowlarr.service),
            port: utils.associateObjectsByKey(this.prowlarr.service.spec.ports, 'name')['webui'].port,
            protocol: 'http',
            api_key: secrets.prowlarr.apiKey,
            settings: {
              apps: {
                applications: {
                  delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                  definitions: {
                    Sonarr: {
                      type: 'sonarr',
                      // Cross-link by name: Buildarr resolves the Sonarr instance above and fills in
                      // its API key itself. The two URLs are still required explicitly (instance_name
                      // only links the key): prowlarr_url is how Sonarr dials back to Prowlarr for the
                      // indexer proxy; base_url is how Prowlarr reaches Sonarr to push the sync.
                      instance_name: sonarrOrionSystemInstanceName,
                      prowlarr_url: httpUrl(
                        utils.domainOfService(this.prowlarr.service),
                        utils.associateObjectsByKey(this.prowlarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      base_url: httpUrl(
                        utils.domainOfService(this.sonarr.service),
                        utils.associateObjectsByKey(this.sonarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      sync_level: 'full_sync',
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  buildarrConnect: buildarr.new(config = buildarrConfig),

  // SeaDexArr: scheduled daemon (no web UI -> no Service/Ingress) that reads the Sonarr library, picks
  // SeaDex's "best" release per anime, and adds its torrent straight into qBittorrent under the
  // tv-sonarr category (so Sonarr imports it) tagged `from-seadexarr`. qBittorrent creds are omitted:
  // its AuthSubnetWhitelist bypasses auth for in-cluster callers (same as buildarr/Sonarr). Radarr
  // isn't deployed, so only Sonarr + qBittorrent are wired; the scheduled run tolerates the absent
  // Radarr per-module. Host/port for each app come from its Service (the source of truth) the same way
  // buildarrConfig does (utils.domainOfService + the webui port looked up by name); API key + Discord
  // webhook come from sops. config.yml is authoritative -- the app reads it read-only and never rewrites it.
  seadexarr: seadexarr.new(
    config = {
      sonarr_url: 'http://%s:%d' % [
        utils.domainOfService(this.sonarr.service),
        utils.associateObjectsByKey(this.sonarr.service.spec.ports, 'name')['webui'].port,
      ],
      sonarr_api_key: secrets.sonarr.apiKey,
      qbit_info: {
        host: 'http://%s:%d' % [
          utils.domainOfService(this.qbittorrent.service),
          utils.associateObjectsByKey(this.qbittorrent.service.spec.ports, 'name')['webui'].port,
        ],
        username: '',
        password: '',
      },
      sonarr_torrent_category: 'tv-sonarr',   // matches Sonarr's qBittorrent download-client category (buildarr)
      torrent_tags: 'from-seadexarr',         // qBittorrent tag on grabs, so SeaDexArr-added torrents are identifiable
      discord_url: secrets.seadexarr.discordUrl,
    },
  ),

  // Public-key-only SFTP front door onto the shared mdata volume (read-write), reached over the
  // tailnet (mdata-sftp.tail4c9a.ts.net:22) and over the LAN via methanol's mDNS alias
  // (mdata-methanol.local:30022 -- alias + firewall port live in venus methanol.nix). Authorized
  // identities: sodium's key and the 1Password key (public keys, mirrored from methanol.nix).
  mdataSftp: sftp.new(
    claimName = this.mdataPvc.metadata.name,
    name = "mdata-sftp",
    tailscaleHostname = "mdata-sftp",
    sftpUser = "mdata",
    nodePort = 30022,
    authorizedKeys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local",  // Yuto's Sodium
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl",  // 1Password "ssh key - main"
    ],
  ),

  // One-stop-shop SSH jump bastion for reaching my personal machines (lib/grand-central.libsonnet).
  // Reached publicly at grand-central.yuto.sh -> CNAME carless-drivers-ddns.andref.app (the
  // NON-proxied ddns record above, so it resolves straight to the home IP -- Cloudflare's proxy
  // can't carry raw SSH) -> home router forwards WAN 30023 -> this NodePort on methanol.
  //
  // ONE list of authorized participant keys (no client/target split). An entry is a bare pubkey
  // string (may open a reverse listener on any loopback port + reach any target), or
  // { key, listenPorts: [..] } pinning which port(s) it may register a reverse listener on. A
  // machine becomes reachable by running its own reverse-tunnel agent on its assigned port (e.g.
  // Sodium's launchd `-R localhost:2222`); add future targets on distinct ports.
  grandCentral: grandCentral.new(
    nodePort = 30023,
    authorizedKeys = [
      // Sodium -- a target pinned to its reverse-listener port 2222 (launchd agent in venus
      // sodium.nix; tunnel priv key in sops secrets/personal/grand-central-tunnel.json).
      { key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBWjndergDSUeNxqTByOVeon92N6X52NaNydd4XUXR2A grand-central-tunnel-sodium", listenPorts: [2222] },
      // magnesium-hydroxide -- a client (also in Sodium's inbound authorized_keys for the final
      // hop). Bare string: may reach any target, no edits here when targets are added.
      //
      // Screen Share INTO Sodium from this client (Standard mode only; VNC rides the ssh jump):
      //   ssh -i ~/.ssh/grand-central -o IdentitiesOnly=yes \
      //       -o ProxyCommand="ssh -i ~/.ssh/grand-central -o IdentitiesOnly=yes -W %h:%p -p 30023 relay@grand-central.yuto.sh" \
      //       -L 5901:127.0.0.1:5900 -p 2222 yuto@localhost
      //   open vnc://localhost:5901
      // (If this client has a `Host sodium` ssh_config block, just: ssh -L 5901:127.0.0.1:5900 sodium)
      // High Performance screen sharing can't traverse grand-central -- it needs native UDP 5900-5902.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKRpVN+BI0l+wj28mUVq3ldRBZUgbsa9CymdCtXF7Vs grand-central yuto.nishida@magnesium-hydroxide",
    ],
  ),

  // Continuously asserts qbittorrent's egress is the VPN exit (not the home IP) and exercises a real
  // ipleak.net torrent magnet; crashloops on a detected leak.
  gluetunLeakTest: gluetunLeakTest.new(),

  cilium: charts.cilium,

  traefikConfig: traefik.reconfigForCilium(),
}