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
local qui = import 'milky-way/lib/qui.libsonnet';
local vpnProxy = import 'milky-way/lib/vpn-proxy.libsonnet';
local thelounge = import 'milky-way/lib/thelounge.libsonnet';
local sonarrForSdxarr = import 'milky-way/lib/sonarr.libsonnet';
local radarrForSdxarr = import 'milky-way/lib/radarr.libsonnet';
local prowlarr = import 'milky-way/lib/prowlarr.libsonnet';
local jellyfin = import 'milky-way/lib/jellyfin.libsonnet';
local seanime = import 'milky-way/lib/seanime.libsonnet';
local shoko = import 'milky-way/lib/shoko.libsonnet';
local suwayomi = import 'milky-way/lib/suwayomi.libsonnet';
local immich = import 'milky-way/lib/immich.libsonnet';
local autobrr = import 'milky-way/lib/autobrr.libsonnet';
local buildarr = import 'milky-way/lib/buildarr.libsonnet';
local seadexarr = import 'milky-way/lib/seadexarr.libsonnet';
local utils = import 'milky-way/lib/utils.libsonnet';
local wgConf = import 'milky-way/lib/wireguard-conf.libsonnet';
local sftp = import 'milky-way/lib/sftp.libsonnet';
local samba = import 'milky-way/lib/samba.libsonnet';
local grandCentral = import 'milky-way/lib/grand-central.libsonnet';
local gluetunLeakTest = import 'milky-way/lib/gluetun-leak-test.libsonnet';
local kubo = import 'milky-way/lib/kubo.libsonnet';
local kuboTest = import 'milky-way/lib/kubo-test.libsonnet';
local andrefIpfsDepot = import 'milky-way/lib/andref-ipfs-depot.libsonnet';
local testExampleWhaleImageDigest = import 'milky-way/lib/test-example-whale-image-digest.libsonnet';
local letsEncryptCloudflare = import 'milky-way/lib/letsencrypt-cloudflare.libsonnet';
local testTraefikAcme = import 'milky-way/lib/test-traefik-acme-ingress.libsonnet';
local secretsRegistry = import 'milky-way/secrets.libsonnet';
local secrets = secretsRegistry['k8s-secret-values.jsonnet'];
// Reusable public keys (SSH). Source of truth: magic/common/public_keys.json, reached via the
// milky-way/vendor/magic -> ../../magic symlink (same mechanism as vendor/exports). See magic/CLAUDE.md.
local pubkeys = import 'magic/common/public_keys.json';
{
  local this = self,

  // Shared name of the Let's Encrypt ClusterIssuer in use, so the issuers (defined in
  // lib/letsencrypt-cloudflare) and anything requesting a cert from one (the test workload below)
  // reference the same string and can't drift. Start on STAGING to validate the DNS-01 wildcard flow
  // without burning prod rate limits; flip `activeLetsEncryptIssuerName` to the prod issuer once
  // staging has verified end-to-end (cert-manager then re-issues into the same Secret from prod).
  local letsEncryptStagingIssuerName = 'letsencrypt-staging',
  local letsEncryptProdIssuerName = 'letsencrypt-prod',
  local activeLetsEncryptIssuerName = letsEncryptProdIssuerName,

  democraticCsiNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "democratic-csi",
    },
  },
  certManagerNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "cert-manager",
    },
  },
  zfsIscsiDriver: charts.zfs_iscsi,
  zfsNfsDriver: charts.zfs_nfs,
  certManager: charts.certManager,
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

  // Let's Encrypt ClusterIssuers (staging + prod) using the cert-manager Cloudflare DNS-01 solver.
  // The CF token (scoped Zone:DNS:Edit + Zone:Read on andref.app) comes from sops.
  letsEncryptCloudflare: letsEncryptCloudflare.new(
    cloudflareDnsApiToken = secrets.certManager.cloudflare.dnsApiToken,
    stagingIssuerName = letsEncryptStagingIssuerName,
    prodIssuerName = letsEncryptProdIssuerName,
  ),

  // Smoke test for the Traefik + cert-manager wildcard cert path: a whoami served over HTTPS at both
  // the apex (test-traefik-acme.andref.app) and a wildcard subdomain, with a single LE cert covering
  // test-traefik-acme.andref.app + *.test-traefik-acme.andref.app.
  testTraefikAcme: testTraefikAcme.new(
    baseDomain = "test-traefik-acme.andref.app",
    issuerName = activeLetsEncryptIssuerName,
  ),

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
      // Grown from 1Ti after the whole volume filled (ZFS refquota hit) and qbittorrent errored
      // large SeaDexArr grabs with "Quota exceeded". The pool has tens of TB free, so the request
      // is the only ceiling; expansion is online (allowVolumeExpansion + NFS refquota bump).
      resources: { requests: { storage: "4Ti" } },
    },
  },

  // Headless qbittorrent whose traffic is forced through a ProtonVPN/WireGuard tunnel by an embedded
  // gluetun sidecar killswitch (lib/gluetun.libsonnet), with NAT-PMP port forwarding so it's
  // connectable for inbound peers (ProtonVPN supports PF; NordVPN does not). WebUI via Tailscale L7
  // ingress. Downloads land in downloads/qbittorrent/ on the shared mdata volume (mounted at /data).
  // The WireGuard key is read straight from the sops-managed ProtonVPN .conf (only Interface.
  // PrivateKey is used; gluetun selects its own PF-capable P2P server).
  qbittorrent: qbittorrent.new(
    wireguardPrivateKey = wgConf.privateKeyOf(secretsRegistry['qbt-gluetun.conf']),
    tailscaleHostname = "qbittorrent",
    vpnProvider = "protonvpn",
    serverCountries = "United States",
    volumeClaimName = this.mdataPvc.metadata.name,
    volumeMountPath = "/data",
    downloadsSubdir = "downloads/qbittorrent",
    // On each COMPLETED torrent in the sonarr-for-sdxarr category, ask Sonarr to do a PATH/file-level
    // import (DownloadedEpisodesScan). This is the recovery path for SeaDex "best" batches whose
    // TOP-LEVEL torrent name lacks a season/episode token (e.g. "Frieren Beyond Journey's End (BD
    // Remux ...)"): Sonarr's queue-based Completed Download Handling parses that name and fails
    // ("Unable to parse"), so it never imports -- but the files inside are "... - S01E01 ...", so a
    // path scan parses each file and imports fine. importMode defaults to "Copy" = HARDLINK on the
    // shared mdata fs (no ~data duplication) with the source kept so the torrent keeps seeding.
    // Same service/port/key/category source-of-truth as the buildarr + seadexarr blocks below.
    onTorrentFinished = {
      sonarrHost: utils.domainOfService(this.sonarrForSdxarr.service),
      sonarrPort: utils.associateObjectsByKey(this.sonarrForSdxarr.service.spec.ports, 'name')['webui'].port,
      sonarrApiKey: secrets.sonarrForSdxarr.apiKey,
      category: 'sonarr-for-sdxarr',
    },
    // On each COMPLETED torrent that carries the `on-finish-hardlink-to-shoko-import` TAG -- or is in
    // the `sonarr-for-sdxarr` category -- hardlink the content into Shoko's drop-source folder
    // (/data/downloads/shoko-drop, on the same mdata fs as the downloads, so the link costs no extra
    // disk and the torrent keeps seeding). Shoko then rename-and-move-organizes it into its library --
    // see the `shoko` field + lib/shoko.libsonnet. The TAG is the primary selector: any producer (a
    // manual add under the `manual` category, an autobrr-direct grab, SeaDexArr) opts a torrent into
    // Shoko by tagging it, so Shoko-import is decoupled from the download category. `sonarr-for-sdxarr`
    // is ALSO kept as a category selector because one of its producers -- Sonarr's own qBittorrent
    // download client, fed by autobrr->Sonarr push filters -- sets only the category and no qBittorrent
    // tags, so a tag alone can't cover it. The handler falls through, so a sonarr-for-sdxarr torrent is
    // hardlinked into Shoko AND still imported by Sonarr (onTorrentFinished above), in both libraries.
    hardlinkOnFinished = {
      tags: ['on-finish-hardlink-to-shoko-import'],
      categories: ['sonarr-for-sdxarr'],
      destDir: '/data/downloads/shoko-drop',
    },
  ),

  // vpn-proxy: a VPN-egress HTTP forward proxy. gluetun's built-in HTTP proxy (:8888) forwards every
  // request through its own ProtonVPN/WireGuard killswitched tunnel -- gluetun is both the tunnel and
  // the proxy, so the pod is gluetun-only (no app container). It runs on a SEPARATE WireGuard key from
  // qbittorrent (the same key on two concurrent ProtonVPN sessions flaps). No web UI -- it's reached
  // in-cluster only, at http://vpn-proxy.default.svc.cluster.local:8888. autobrr points its IRC proxy
  // there (configured in autobrr's UI; that's runtime DB state, not config-as-code here).
  vpnProxy: vpnProxy.new(
    wireguardPrivateKey = wgConf.privateKeyOf(secretsRegistry['gluetun-vpn-proxy.conf']),
    vpnProvider = "protonvpn",
    serverCountries = "United States",
  ),

  // TheLounge: self-hosted web IRC client in PRIVATE mode (config.js public:false -> named users log
  // in, sessions persist while away). Its IRC traffic is forced through a ProtonVPN/WireGuard tunnel
  // by an embedded gluetun sidecar killswitch (same pattern as qbittorrent) so the home IP is never
  // exposed to IRC networks -- TheLounge has no app-level proxy setting for IRC, so the hiding is done
  // at the network layer (it can't use the HTTP-CONNECT vpn-proxy above). SEPARATE WireGuard key from
  // qbittorrent/vpn-proxy (the same key on concurrent ProtonVPN sessions flaps). WebUI via Tailscale
  // L7 ingress. Create logins post-deploy:
  //   kubectl --context methanol exec deploy/thelounge -- s6-setuidgid abc thelounge add <user>
  thelounge: thelounge.new(
    wireguardPrivateKey = wgConf.privateKeyOf(secretsRegistry['thelounge-gluetun.conf']),
    tailscaleHostname = "thelounge",
    vpnProvider = "protonvpn",
    serverCountries = "United States",
  ),

  // sonarr-for-sdxarr: the Sonarr instance dedicated to being reconciled by SeaDexArr (hence the
  // name -- its supported use-case is the seadexarr wiring below, NOT a general/global Sonarr).
  // Monitors/grabs TV episodes, hands torrents to qbittorrent
  // (qbittorrent.default.svc.cluster.local:8080), then imports completed downloads by hardlinking
  // them out of /data/downloads/qbittorrent into a library tree ('/data/library/Animations (Seadexarr)',
  // set as the Sonarr root folder via buildarrConfig below --
  // the '(Seadexarr)' suffix marks it as this instance's SeaDexArr-managed root) on the
  // SHARED mdata volume -- same PVC, same /data mount path as qbittorrent, so hardlinks/atomic
  // moves stay on one filesystem. WebUI via Tailscale L7 ingress; SQLite config on its own iSCSI
  // RWO PVC. The download-client/indexer links are entered in the UI post-deploy (they need API
  // keys each app generates on first boot).
  sonarrForSdxarr: sonarrForSdxarr.new(
    apiKey = secrets.sonarrForSdxarr.apiKey,
    tailscaleHostname = "sonarr-for-sdxarr",
    name = "sonarr-for-sdxarr",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // radarr-for-sdxarr: the Radarr instance dedicated to being reconciled by SeaDexArr -- the anime
  // MOVIE counterpart of sonarr-for-sdxarr (which handles series). Its supported use-case is the
  // seadexarr wiring below, NOT a general/global Radarr. Monitors/grabs movies, hands torrents to
  // qbittorrent (qbittorrent.default.svc.cluster.local:8080), then imports completed downloads by
  // hardlinking them out of /data/downloads/qbittorrent into a library tree
  // ('/data/library/Animation Movies (Seadexarr)', set as the Radarr root folder via buildarrConfig
  // below -- the '(Seadexarr)' suffix marks it as this instance's SeaDexArr-managed root) on the
  // SHARED mdata volume -- same PVC, same /data mount path as qbittorrent, so hardlinks/atomic moves
  // stay on one filesystem. WebUI via Tailscale L7 ingress; SQLite config on its own iSCSI RWO PVC.
  // The download-client/indexer links are entered in the UI post-deploy (they need API keys each app
  // generates on first boot).
  radarrForSdxarr: radarrForSdxarr.new(
    apiKey = secrets.radarrForSdxarr.apiKey,
    tailscaleHostname = "radarr-for-sdxarr",
    name = "radarr-for-sdxarr",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // Prowlarr: indexer manager. No media volume -- it pushes indexer configs to the *arr apps
  // (sonarr-for-sdxarr.default.svc.cluster.local:8989 and radarr-for-sdxarr...:7878) over ClusterIP
  // DNS. WebUI via Tailscale L7 ingress; SQLite config on its own iSCSI RWO PVC.
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

  // Seanime: self-hosted anime media server reading the shared mdata library READ-ONLY. Scans and
  // streams /data/library/... (same PVC as jellyfin/sonarr) but never writes it -- it tracks watch
  // progress in its own SQLite DB on a separate iSCSI RWO config PVC. First-run is interactive
  // (AniList OAuth in the UI), so no Secret/buildarr. WebUI via Tailscale L7 ingress. Post-deploy,
  // set the library folder to /data/library in the UI.
  seanimeRo: seanime.new(
    name = "seanime-ro",
    tailscaleHostname = "seanime-ro",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
    mediaReadOnly = true,
    // Server password (sops) -> satisfies Seanime's privileged-settings CSRF guard over the tailnet
    // L7 ingress (origin-trust alone can't); the UI prompts for it on load. See lib/seanime.libsonnet.
    serverPassword = secrets.seanime.serverPassword,
  ),

  // Shoko: AniDB-hash-based anime organizer for anime downloaded MANUALLY (distinct from the
  // automated SeaDex -> Sonarr path). Workflow: add a torrent in qbittorrent (typically under the
  // `manual` category) and give it the `on-finish-hardlink-to-shoko-import` tag -> qbittorrent's
  // on-complete hook hardlinks it into /data/downloads/shoko-drop (Shoko's Drop Source) -> Shoko
  // hashes/identifies it against AniDB and rename-and-move-organizes it into /data/library/Anime
  // (Shoko) (its Drop Destination), all on the one shared mdata volume so the move preserves the inode
  // (torrent keeps seeding, one physical copy). Shoko can't hardlink itself, so the hardlink is done by
  // qbittorrent's `hardlinkOnFinished` hook above (tag-driven, plus the sonarr-for-sdxarr category).
  // Like jellyfin, its
  // config (AniDB creds, import folders, WebAOM renamer, local users) is set in an interactive
  // first-run -- so no config-as-code / Secret / buildarr. WebUI via Tailscale L7 ingress; SQLite +
  // metadata cache on its own iSCSI RWO PVC. Jellyfin views this library via the Shokofin plugin
  // (configured in Jellyfin's UI); read-only Seanime picks it up automatically (it scans /data/library).
  shoko: shoko.new(
    tailscaleHostname = "shoko",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // Suwayomi: self-hosted manga reader/server -- the manga counterpart to the anime stack. Installs
  // Mihon/Tachiyomi extensions and downloads chapters, storing its bulk media on the shared mdata
  // volume: downloaded manga in downloads/suwayomi and the local-source library in
  // 'library/Manga (Suwayomi)' (both overlaid onto the fixed datadir paths via subPath mounts --
  // Suwayomi refuses to reconfigure its downloads path, so a mounted volume is the intended relocation
  // mechanism). Only its SQLite/H2 DB + extensions + thumbnail cache stay on an iSCSI RWO config PVC.
  // Runs non-root as UID 1000 (root init chowns the config PVC; a second root init pre-creates the two
  // mdata subdirs). WebUI via Tailscale L7 ingress; first-run (extensions/sources/library) is
  // interactive, so no Secret / config-as-code. See lib/suwayomi.libsonnet.
  suwayomi: suwayomi.new(
    tailscaleHostname = "suwayomi",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
    // HTTP Basic auth (defense-in-depth on top of the tailnet-only ingress). Credentials are
    // sops-backed and injected via a Secret/secretKeyRef, so they never appear in the Deployment.
    authMode = "basic_auth",
    authUsername = secrets.suwayomi.username,
    authPassword = secrets.suwayomi.password,
  ),

  // Immich for band-practice photos/videos: a DEDICATED Immich instance, isolated from the anime
  // stack above (its own DB + its own library volume; it does NOT touch the shared mdata PVC). It's
  // this cluster's first multi-datastore app -- lib/immich.libsonnet hand-writes the Postgres
  // (bespoke VectorChord image, iSCSI RWO PVC), the Valkey job queue (ephemeral), and the
  // immich-server, plus their wiring. The photo/video library is a dedicated NFS RWX PVC (bulk media
  // wants NFS; the DB stays on iSCSI since a DB is unsafe on NFS). WebUI via Tailscale L7 ingress;
  // first-run admin setup + all config is interactive in the UI, so the only secret is the DB
  // password (sops), shared by Postgres + the server via a Secret/secretKeyRef.
  immichForCDBand: immich.new(
    name = "immich-for-cd-band",
    tailscaleHostname = "immich-for-cd-band",
    dbPassword = secrets.immichForCDBand.dbPassword,
    // Also expose publicly over HTTPS at cd-jams.andref.app (CNAME -> carless-drivers-ddns in eight/).
    // Traefik `websecure` ingress + a cert-manager LE cert from the shared prod ClusterIssuer.
    publicHostname = "cd-jams.andref.app",
    issuerName = activeLetsEncryptIssuerName,
  ),

  // autobrr: download automation. Watches indexer announces (IRC/RSS), matches releases against
  // filters, and forwards each match to a download client -- typically Sonarr as an "arr" client
  // (Sonarr then grabs via its own qBittorrent client under sonarr-for-sdxarr, owning the category), or
  // qBittorrent directly under a per-filter category. No media volume / no VPN sidecar: it hands
  // releases to Sonarr / qBittorrent over ClusterIP, it isn't a torrent client itself. The download
  // clients + indexers + filters + categories are runtime UI/DB state -- autobrr has no
  // config-as-code for them, so they are NOT declared here (contrast buildarr above). SQLite config
  // (incl. a self-generated sessionSecret) on its own iSCSI RWO PVC; WebUI via Tailscale L7 ingress.
  autobrr: autobrr.new(
    tailscaleHostname = "autobrr",
  ),

  // qui (by autobrr): a modern multi-instance WebUI for qBittorrent, exposed over Tailscale L7 like the
  // rest of the media-stack UIs. It manages the gluetun-fronted `qbittorrent` above -- but that
  // qBittorrent connection is RUNTIME state added in qui's UI post-deploy (reached in-cluster with no
  // creds via qBittorrent's AuthSubnetWhitelist), NOT config-as-code here. Mounts the shared mdata
  // volume read-write at /data (matching qbittorrent's mount) so qui's Local Filesystem features
  // (orphan scan / hardlink / reflink / automations) can operate on the same paths. SQLite config on
  // its own iSCSI RWO PVC; session secret self-generated + persisted there (see lib/qui.libsonnet).
  qui: qui.new(
    tailscaleHostname = "qui",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
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
    local sonarrForSdxarrInstanceName = 'sonarr-for-sdxarr';
    local radarrForSdxarrInstanceName = 'radarr-for-sdxarr';
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
          [sonarrForSdxarrInstanceName]: {
            hostname: utils.domainOfService(this.sonarrForSdxarr.service),
            port: utils.associateObjectsByKey(this.sonarrForSdxarr.service.spec.ports, 'name')['webui'].port,
            protocol: 'http',
            api_key: secrets.sonarrForSdxarr.apiKey,
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
                    category: 'sonarr-for-sdxarr',  // qBittorrent category Sonarr tags its grabs with
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
                  this.sonarrForSdxarr.deployment.spec.template.spec.containers[0].volumeMounts, 'name'
                )['media'],
                assert mediaMount.mountPath == '/data' :
                  'sonarr media mount must be at /data for these buildarr root_folders to resolve',
                root_folders: [
                  '/data/library/Animations (Seadexarr)',
                ],
              },
            },
          },
        },
      },
      radarr: {
        // GLOBAL defaults for all radarr instances (current + future). MUST stay false -- never
        // clobber download clients (or root folders) added by hand in Radarr's UI. NOTE the shape
        // DIFFERS from the sonarr block above: buildarr-radarr (0.2.6, bundled in the pinned
        // callum027/buildarr:0.7.8) NESTS root folders under
        // media_management.root_folders.{delete_unmanaged, definitions} and has NO
        // media_management.delete_unmanaged_root_folders field (buildarr-sonarr uses a flat list +
        // that sibling boolean). Wrong field names render fine in jsonnet but break buildarr's
        // runtime reconcile.
        settings: {
          download_clients: { delete_unmanaged: false },
          media_management: { root_folders: { delete_unmanaged: false } },
        },
        instances: {
          [radarrForSdxarrInstanceName]: {
            hostname: utils.domainOfService(this.radarrForSdxarr.service),
            port: utils.associateObjectsByKey(this.radarrForSdxarr.service.spec.ports, 'name')['webui'].port,
            protocol: 'http',
            api_key: secrets.radarrForSdxarr.apiKey,
            settings: {
              download_clients: {
                delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                definitions: {
                  qBittorrent: {
                    type: 'qbittorrent',
                    // buildarr-radarr's qBittorrent client field is `hostname` (buildarr-sonarr uses
                    // `host`) -- verified against buildarr-radarr 0.2.6 (it remote-maps to qBittorrent's host).
                    hostname: utils.domainOfService(this.qbittorrent.service),
                    port: utils.associateObjectsByKey(this.qbittorrent.service.spec.ports, 'name')['webui'].port,
                    // No username/password: qBittorrent's AuthSubnetWhitelist bypasses auth for
                    // in-cluster callers (Radarr is in the pod CIDR). See lib/qbittorrent.libsonnet.
                    category: 'radarr-for-sdxarr',  // qBittorrent category Radarr tags its grabs with
                  },
                },
              },
              media_management: {
                // Movie naming / media-management rules, asserted declaratively so they self-heal on
                // the hourly reconcile instead of being hand-set in the UI. Mirrors the sonarr block's
                // intent with Radarr's movie tokens/fields.
                rename_movies: true,
                replace_illegal_characters: true,
                // buildarr-radarr 0.2.6 has NO 'smart' colon replacement (only delete/dash/spaceDash/
                // spaceDashSpace), so Radarr's native "Smart Replace" default can't be expressed here.
                // 'dash' is the closest filesystem-safe approximation (colon -> '-'). GOTCHA: Radarr 6.x
                // SHIPS colonReplacementFormat='smart', which buildarr-radarr 0.2.6's bundled API client
                // can't even DESERIALIZE -- so on a FRESH Radarr config buildarr's from_remote fetch
                // crashes (ValidationError) before it can set this. One-time bootstrap on a new config
                // PVC: PUT /api/v3/config/naming/1 with colonReplacementFormat set to any legacy value
                // ('dash') so buildarr can read it; buildarr then holds it at 'dash' every reconcile.
                colon_replacement: 'dash',
                standard_movie_format: '{Movie CleanTitle} ({Release Year}) [{Quality Full}]{[MediaInfo VideoDynamicRangeType]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}[{Mediainfo AudioCodec} {Mediainfo AudioChannels}]{MediaInfo AudioLanguages}{-Release Group}',
                movie_folder_format: '{Movie CleanTitle} ({Release Year}) [imdb-{ImdbId}]',
                // This root folder is a path INSIDE the Radarr container -- the `mdata` PVC, which
                // Radarr mounts at /data (matching qbittorrent so hardlinks stay on one fs). Look up
                // the media mount by name, then assert that mount is /data, so a future mediaMountPath
                // change (or a renamed mount) fails at evaluation instead of silently leaving this root
                // folder pointing where Radarr no longer mounts (its API rejects a non-existent path).
                // The path below stays LITERAL on purpose. NOTE: nested under root_folders per the
                // buildarr-radarr shape (see the global-settings note above).
                local mediaMount = utils.associateObjectsByKey(
                  this.radarrForSdxarr.deployment.spec.template.spec.containers[0].volumeMounts, 'name'
                )['media'],
                assert mediaMount.mountPath == '/data' :
                  'radarr media mount must be at /data for these buildarr root_folders to resolve',
                root_folders: {
                  delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                  definitions: [
                    '/data/library/Animation Movies (Seadexarr)',
                  ],
                },
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
                      instance_name: sonarrForSdxarrInstanceName,
                      prowlarr_url: httpUrl(
                        utils.domainOfService(this.prowlarr.service),
                        utils.associateObjectsByKey(this.prowlarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      base_url: httpUrl(
                        utils.domainOfService(this.sonarrForSdxarr.service),
                        utils.associateObjectsByKey(this.sonarrForSdxarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      // DISABLED on purpose: sonarr-for-sdxarr is a SeaDex-only instance. If Prowlarr
                      // pushed indexers here, Sonarr's RSS/auto-search would grab non-SeaDex releases on
                      // its own, competing with SeaDexArr -- and since every quality profile has
                      // upgradeAllowed=false, whichever release lands first wins forever, so a weekly
                      // Nyaa grab would permanently block SeaDexArr's curated BD release from ever
                      // importing. The app entry is KEPT (not deleted) so Buildarr still owns the
                      // Prowlarr<->Sonarr link; only the indexer sync is turned off. (All of Sonarr's
                      // other settings -- naming, root folders, download client -- come from the
                      // `sonarr:` instance block above, not from here.) NOTE: Buildarr's Prowlarr
                      // reconcile is currently broken (an empty-apikey indexer trips pydantic), so this
                      // was ALSO applied at runtime via the Prowlarr API. Flip back to 'full_sync' only
                      // if this instance should ever search indexers on its own.
                      sync_level: 'disabled',
                    },
                    Radarr: {
                      type: 'radarr',
                      // Cross-link by name: Buildarr resolves the Radarr instance above and fills in
                      // its API key itself. The two URLs are still required explicitly (instance_name
                      // only links the key): prowlarr_url is how Radarr dials back to Prowlarr for the
                      // indexer proxy; base_url is how Prowlarr reaches Radarr to push the sync.
                      instance_name: radarrForSdxarrInstanceName,
                      prowlarr_url: httpUrl(
                        utils.domainOfService(this.prowlarr.service),
                        utils.associateObjectsByKey(this.prowlarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      base_url: httpUrl(
                        utils.domainOfService(this.radarrForSdxarr.service),
                        utils.associateObjectsByKey(this.radarrForSdxarr.service.spec.ports, 'name')['webui'].port,
                      ),
                      // DISABLED on purpose: radarr-for-sdxarr is a SeaDex-only instance, same reasoning
                      // as the Sonarr app above -- if Prowlarr pushed indexers here, Radarr's RSS/auto-search
                      // would grab non-SeaDex releases competing with SeaDexArr, and since every quality
                      // profile has upgradeAllowed=false, whichever release lands first wins forever, so an
                      // on-its-own grab would permanently block SeaDexArr's curated release from ever
                      // importing. The app entry is KEPT (not deleted) so Buildarr still owns the
                      // Prowlarr<->Radarr link; only the indexer sync is turned off. As with Sonarr,
                      // Buildarr's Prowlarr reconcile is currently broken (an empty-apikey indexer trips
                      // pydantic), so this was ALSO applied at runtime via the Prowlarr API. Flip to
                      // 'full_sync' only if this instance should ever search indexers on its own.
                      sync_level: 'disabled',
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

  // SeaDexArr: scheduled daemon (no web UI -> no Service/Ingress) that reads the Sonarr AND Radarr
  // libraries, picks SeaDex's "best" release per anime series/movie, and adds its torrent straight
  // into qBittorrent under the matching *arr category (sonarr-for-sdxarr / radarr-for-sdxarr, so the
  // owning *arr imports it) tagged `from-seadexarr`. qBittorrent creds are omitted: its
  // AuthSubnetWhitelist bypasses auth for in-cluster callers (same as buildarr/Sonarr/Radarr). Both
  // *arr modules are now wired (Radarr manages anime movies, the movie counterpart to Sonarr's
  // series). Host/port for each app come from its Service (the source of truth) the same way
  // buildarrConfig does (utils.domainOfService + the webui port looked up by name); API keys +
  // Discord webhook come from sops. config.yml is authoritative -- the app reads it read-only and
  // never rewrites it.
  seadexarr: seadexarr.new(
    config = {
      sonarr_url: 'http://%s:%d' % [
        utils.domainOfService(this.sonarrForSdxarr.service),
        utils.associateObjectsByKey(this.sonarrForSdxarr.service.spec.ports, 'name')['webui'].port,
      ],
      sonarr_api_key: secrets.sonarrForSdxarr.apiKey,
      radarr_url: 'http://%s:%d' % [
        utils.domainOfService(this.radarrForSdxarr.service),
        utils.associateObjectsByKey(this.radarrForSdxarr.service.spec.ports, 'name')['webui'].port,
      ],
      radarr_api_key: secrets.radarrForSdxarr.apiKey,
      qbit_info: {
        host: 'http://%s:%d' % [
          utils.domainOfService(this.qbittorrent.service),
          utils.associateObjectsByKey(this.qbittorrent.service.spec.ports, 'name')['webui'].port,
        ],
        username: '',
        password: '',
      },
      sonarr_torrent_category: 'sonarr-for-sdxarr',   // matches Sonarr's qBittorrent download-client category (buildarr)
      radarr_torrent_category: 'radarr-for-sdxarr',   // matches Radarr's qBittorrent download-client category (buildarr)
      // qBittorrent tags on grabs: `from-seadexarr` (provenance) + `on-finish-hardlink-to-shoko-import`
      // (marks SeaDexArr grabs Shoko-bound). Comma-separated, no space -- qBittorrent splits on comma.
      torrent_tags: 'from-seadexarr,on-finish-hardlink-to-shoko-import',
      discord_url: secrets.seadexarr.discordUrl,
    },
    // Poll every 10 minutes. SCHEDULE_TIME is float HOURS (app does time.sleep(SCHEDULE_TIME*3600)),
    // so 10/60. The sleep runs AFTER each full pass, so passes never overlap regardless of interval.
    // Kept at 10m (not 1m) to avoid hammering the SeaDex/AniList APIs, which change on the order of days.
    scheduleHours = 10.0 / 60,
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
      pubkeys.ssh.yutoSodium,  // Yuto's Sodium
      pubkeys.ssh.onePasswordMain,  // 1Password "ssh key - main"
    ],
  ),

  // SMB server dedicated to Apple-device backups (lib/samba.libsonnet), reached over the tailnet on
  // its own dedicated RWX NFS PVC (smb-share-for-apple-devices-backups-data) -- kept off the shared
  // media volume. Two shares, each a subdir of the one PVC:
  //   - smb://apple-backups.tail4c9a.ts.net/timemachine  -> macOS Time Machine target (fruit VFS).
  //     AUTHENTICATED (user `timemachine`, password from sops): Time Machine forces a private 0700
  //     share root, which only a session that OWNS it can write -- a guest never can. macOS expects
  //     to authenticate to network TM destinations anyway.
  //   - smb://apple-backups.tail4c9a.ts.net/backups      -> GUEST plain share for other backups /
  //     manual file drops, incl. the iOS/iPadOS Files app. NOTE iOS/iPadOS cannot back up to SMB
  //     directly (iCloud or a Mac/PC only), so for those devices this is manual file storage.
  smbShareForAppleDevicesBackups: samba.new(
    name = "smb-share-for-apple-devices-backups",
    tailscaleHostname = "apple-backups",   // free choice; must be tailnet-unique (cleaner mount URL than the long name)
    storageSize = "1Ti",
    users = {
      // Time Machine user; password from sops (secrets.smb.appleDevicesBackupsTimemachinePassword).
      timemachine: { uid: 1000, password: secrets.smb.appleDevicesBackupsTimemachinePassword },
    },
    shares = [
      { name: "timemachine", user: "timemachine", timeMachine: true, timeMachineMaxSize: "1T" },  // cap so TM can't fill the pool; tune to taste
      { name: "backups" },                                                                         // guest; other backups / iOS Files-app drops
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
      { key: pubkeys.ssh.sodiumForGrandCentral, listenPorts: [2222] },
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
      pubkeys.ssh.magnesiumHydroxideForGrandCentral,
    ],
  ),

  // Continuously asserts qbittorrent's egress is the VPN exit (not the home IP) and exercises a real
  // ipleak.net torrent magnet; crashloops on a detected leak.
  gluetunLeakTest: gluetunLeakTest.new(),

  // kubo (IPFS) pinned-mirror node, VPN-fronted (gluetun/ProtonVPN with NAT-PMP port forwarding, so
  // it's a reachable provider, not just outbound). Gateway.NoFetch + Provide.Strategy=pinned mean it
  // only serves and announces allowlisted (pinned) content; the home IP is never exposed to the IPFS
  // swarm. The admin RPC API is locked down with API.Authorizations and stays ClusterIP-only; kubo's
  // built-in /webui is exposed tailnet-only (https://ipfs-webui.<tailnet>.ts.net) via a token-injecting
  // nginx sidecar, using the dedicated full-/api/v0 webui token. Its OWN ProtonVPN WireGuard session/key
  // (a 4th concurrent tunnel; the same key on concurrent sessions flaps), read from the sops-managed
  // .conf like qbittorrent. The HTTP gateway is ALSO published PUBLICLY as a subdomain gateway at
  // ipfs.andref.app / *.ipfs.andref.app (cert-manager wildcard cert, served by Traefik) -- this exposes
  // the home IP for gateway HTTP only; the swarm/DHT still leaves only from the VPN exit.
  kubo: kubo.new(
    testRpcToken = secrets.kubo.rpcTokenForTest,
    webuiRpcToken = secrets.kubo.rpcTokenForIpfsWebui,
    // Third, least-privilege RPC grant (scoped to /api/v0/add) for the andref-ipfs-depot uploader.
    depotRpcToken = secrets.kubo.rpcTokenForAndrefIpfsDepot,
    tailscaleHostname = "ipfs-webui",
    wireguardPrivateKey = wgConf.privateKeyOf(secretsRegistry['kubo-gluetun.conf']),
    vpnProvider = "protonvpn",
    serverCountries = "United States",
    // Public subdomain IPFS gateway: content served origin-isolated at https://<cid>.ipfs.andref.app,
    // plus a path-gateway landing at ipfs.andref.app; TLS via the cert-manager wildcard cert. The
    // PublicGateways KEY is the bare zone "andref.app" (kubo serves at <cid>.ipfs.<key>), so it must
    // equal gatewayBaseDomain with its leading "ipfs." label stripped (asserted in lib/kubo.libsonnet).
    gatewayBaseDomain = "ipfs.andref.app",
    gatewayPublicGatewayKey = "andref.app",
    gatewayIssuerName = activeLetsEncryptIssuerName,
  ),

  // Scoped verifier: the ONLY authorized RPC client, granted the minimum API.Authorizations
  // AllowedPaths needed to prove the node mirrors/serves only pinned content (and that its egress is
  // the VPN). Crashloops on a confirmed violation. Host/ports are read from kubo's Service.
  kuboTest: kuboTest.new(
    rpcToken = secrets.kubo.rpcTokenForTest,
    kuboService = this.kubo.service,
  ),

  // andref-ipfs-depot: Discord-gated file uploader for the kubo pinned-mirror node
  // (lib/andref-ipfs-depot.libsonnet). A guild member runs /upload, gets a single-use link, uploads
  // a file via the public page, and the backend pins it to kubo (the scoped 'depot' RPC token above)
  // and returns + posts back the subdomain-gateway link https://<cid>.ipfs.andref.app. The HTTP
  // server is public (depot.andref.app, Traefik + cert-manager wildcard issuer); the bot is
  // outbound-only. kubo's RPC is reached in-cluster via its Service (host + api port read from it).
  andrefIpfsDepot: andrefIpfsDepot.new(
    discordBotToken = secrets.discordBots.andrefIpfsDepot.token,
    discordGuildId = secrets.discord.andref.guildId,
    kuboRpcToken = secrets.kubo.rpcTokenForAndrefIpfsDepot,
    kuboRpcBase = 'http://%s:%d' % [
      utils.domainOfService(this.kubo.service),
      utils.associateObjectsByKey(this.kubo.service.spec.ports, 'name')['api'].port,
    ],
    publicHostname = "depot.andref.app",
    gatewayBaseDomain = "ipfs.andref.app",
    issuerName = activeLetsEncryptIssuerName,
  ),

  cilium: charts.cilium,

  traefikConfig: traefik.reconfigForCilium(),
}