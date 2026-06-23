local images = {
  local this = self,

  // Render a pinned image reference from a digest object { hash, tagHint? }. The hash (e.g.
  // "sha256:abc...") is what's enforced; the optional tagHint (e.g. "v3.41.1") is folded in purely
  // for human readability -> "repo:tagHint@sha256:..." when present, "repo@sha256:..." otherwise.
  local pinnedRef(repository, digest) =
    repository + (if std.objectHas(digest, "tagHint") then ":" + digest.tagHint else "") + "@" + digest.hash,

  // Render a tagged image reference -> "repo:tag".
  local taggedRef(repository, tag) = repository + ":" + tag,

  /**
   * For each image, we have a dictionary of relevant data.
   * - fullyQualifiedRepository: the repository part of the image reference, without tag or digest.
   * - defaultDigest: a digest object { hash, tagHint? } used as the default pin for the `image` parameter commonly accepted by a `new()` constructor for instantiating the service. `hash` is the immutable digest ("sha256:..."); the optional `tagHint` is a human-readable version tag folded into the rendered reference (NOT enforced -- the digest is).
   * - defaultTag: a tag string used as the default for the `image` parameter when no digest is available. DEPRECATED, only for migrating off inline tag strings.
   * - tagFor<Consumer> / digestFor<Consumer>: for an image shared by multiple consumers at (possibly) different versions (e.g. busybox as an init/helper image, or traefik/whoami across smoke tests), name one property per consumer rather than a single `default`. A digestFor<Consumer> is also a { hash, tagHint? } object. Each yields a per-consumer reference field below.
   * - fullyQualifiedImageReferencePinned: the rendered pinned reference, "repo[:tagHint]@hash" (e.g. "docker.io/yuto7/mopidy@sha256:abc123..."). This is what should be used in the `image` field of the container spec for maximum immutability and reproducibility.
   * - fullyQualifiedImageReferenceTagged: the fully qualified tagged image reference with a tag (e.g. "docker.io/yuto7/mopidy:latest"). This is DEPRECATED and only here for migration.
   * - fullyQualifiedImageReferencePinnedFor<Consumer> / fullyQualifiedImageReferenceTaggedFor<Consumer>: the per-consumer counterparts of the above, derived from a digestFor<Consumer>/tagFor<Consumer> raw property.
   *
   * Whale digest hashes are read from exports/whale/digests/<name>.txt (written by
   * `nix run ./flake-profiles/whale#whale-push-<name>`), resolved via the
   * vendor/exports -> ../../exports jpath symlink. std.trim handles digest files
   * with or without a trailing newline.
   */
  raw: {
    mopidy: {
      fullyQualifiedRepository: "docker.io/yuto7/mopidy",
      defaultDigest: { hash: std.trim(importstr "exports/whale/digests/mopidy.txt") },
    },
    "example-image": {
      fullyQualifiedRepository: "docker.io/yuto7/example-image",
      defaultDigest: { hash: std.trim(importstr "exports/whale/digests/example-image.txt") },
    },
    // Minimal openssh "binary carrier" for the grand-central jump bastion (whale-built); all
    // policy/config is mounted, so the pin just tracks the binaries. See whale/outputs.nix.
    "grand-central": {
      fullyQualifiedRepository: "docker.io/yuto7/grand-central",
      defaultDigest: { hash: std.trim(importstr "exports/whale/digests/grand-central.txt") },
    },
    // Third-party images pinned by digest (the hash is enforced; tagHint is the readable version).
    gluetun: {
      fullyQualifiedRepository: "qmcgaw/gluetun",
      defaultDigest: { hash: "sha256:2f33c71e5e164fcd51a962cb950134df25155593edf0c3e1201f888d027049b4", tagHint: "v3.41.1" },
    },
    python: {
      fullyQualifiedRepository: "python",
      defaultDigest: { hash: "sha256:2d07747661646f3d904e995a232fb19e461afde69e67e6f7f3b52c7b968a88b3", tagHint: "3.12-alpine" },
    },
    qbittorrent: {
      fullyQualifiedRepository: "lscr.io/linuxserver/qbittorrent",
      defaultDigest: { hash: "sha256:1784d5a65d08d01de308c7d87ff2c1dba328379e180eeca41cc6b96bdf6a0ffc", tagHint: "5.2.1" },
    },
    // *arr media-management apps (LinuxServer.io). The hash is the multi-arch INDEX digest (k3s
    // resolves the per-node arch), matching the qbittorrent pin above; tagHint is the readable
    // LinuxServer version. Re-resolve with `docker buildx imagetools inspect <repo>:latest`.
    sonarr: {
      fullyQualifiedRepository: "lscr.io/linuxserver/sonarr",
      defaultDigest: { hash: "sha256:02bc962946fef994e67a38152446df25c10a52f8583aefeeb6467f9dd44cab99", tagHint: "4.0.17.2952-ls314" },
    },
    prowlarr: {
      fullyQualifiedRepository: "lscr.io/linuxserver/prowlarr",
      defaultDigest: { hash: "sha256:7ab5769616c1929247c8e7944453253f0b777fac2724c3bc9976ae2ff4023257", tagHint: "2.4.0.5397-ls150" },
    },
    // Jellyfin media server (LinuxServer.io): plays the library the *arr stack builds on the
    // shared mdata volume. Same multi-arch INDEX digest convention as the *arr/qbittorrent pins
    // above (k3s resolves the per-node arch); tagHint is the readable LinuxServer version.
    // Re-resolve with `docker buildx imagetools inspect lscr.io/linuxserver/jellyfin:latest`.
    jellyfin: {
      fullyQualifiedRepository: "lscr.io/linuxserver/jellyfin",
      defaultDigest: { hash: "sha256:bb8ff21a879498dbdead9efe4d3de2070dbda2b9fb35b9a43501055f6e526384", tagHint: "10.11.11ubu2404-ls37" },
    },
    // TheLounge web IRC client (LinuxServer.io). Multi-arch INDEX digest (k3s resolves the per-node
    // arch), same convention as the *arr/qbittorrent/jellyfin pins; tagHint is the readable
    // LinuxServer version. Re-resolve with
    // `docker buildx imagetools inspect lscr.io/linuxserver/thelounge:latest`.
    thelounge: {
      fullyQualifiedRepository: "lscr.io/linuxserver/thelounge",
      defaultDigest: { hash: "sha256:07f9dc09e4a781d4ee38a06378c183005b28b9872b98a8a31cfb4c315ba23fdc", tagHint: "v4.5.0-ls223" },
    },
    // Buildarr: declaratively reconciles *arr state (used here only to wire Sonarr<->Prowlarr<->
    // qBittorrent together). The image bundles the sonarr/radarr/prowlarr plugins. The hash is the
    // multi-arch INDEX digest (same as the *arr/qbittorrent pins above; k3s resolves the per-node
    // arch); tagHint is the readable release. Re-resolve with
    // `docker buildx imagetools inspect callum027/buildarr:latest`.
    buildarr: {
      fullyQualifiedRepository: "callum027/buildarr",
      defaultDigest: { hash: "sha256:57e2343fefe5d5701364b5e93b4985dbf08310d7b152f70556bdaba7e9475447", tagHint: "0.7.8" },
    },
    // SeaDexArr (bbtufty): scheduled daemon syncing Sonarr/Radarr anime picks from SeaDex into
    // qBittorrent. SINGLE-ARCH amd64 manifest (matches methanol's x86_64) -- the digest is that one
    // manifest, not a multi-arch index. Re-resolve with
    // `docker buildx imagetools inspect ghcr.io/bbtufty/seadexarr:main`.
    //
    // Pinned to the `:main` build (2026-01-12), NOT the v0.9.0 release: v0.9.0 ships
    // qbittorrent-api==2025.7.0, whose auth_log_in() requires the login body to be "Ok." and so
    // CRASHES against our qBittorrent, which uses an AuthSubnetWhitelist that bypasses login for
    // in-cluster callers and answers /api/v2/auth/login with `204 No Content` (empty body) instead.
    // `:main` bumps to qbittorrent-api==2025.11.1, which counts an empty body as success -- so the
    // whitelist bypass works and qBittorrent needs no password. Move to the next tagged release
    // (>v0.9.0) once one ships with that bump.
    seadexarr: {
      fullyQualifiedRepository: "ghcr.io/bbtufty/seadexarr",
      defaultDigest: { hash: "sha256:92d539222696bd312c372ee8c6915141025ea10c1daa1a5ebded2966236fdebf", tagHint: "main" },
    },
    // autobrr: download-automation tool (monitors IRC announce / RSS, matches releases against
    // filters, forwards each to a download client -- here qBittorrent under a per-filter category).
    // Multi-arch INDEX digest (k3s resolves the per-node arch), same convention as the *arr/
    // qbittorrent pins; tagHint is the readable release. Re-resolve with
    // `docker buildx imagetools inspect ghcr.io/autobrr/autobrr:<tag>`.
    autobrr: {
      fullyQualifiedRepository: "ghcr.io/autobrr/autobrr",
      defaultDigest: { hash: "sha256:944b1c438302ed10bef810a49f2eb7f334b5abf578db473bcb8d997db3978227", tagHint: "v1.80.0" },
    },
    // Kubo (go-ipfs), the reference IPFS implementation -- run here as a VPN-fronted pinned-mirror
    // node (lib/kubo.libsonnet). Multi-arch INDEX digest (k3s resolves the per-node arch; the index
    // includes linux/amd64 for methanol), same convention as the *arr/qbittorrent pins; tagHint is
    // the readable version. v0.42.0 has the Provide.* config section (Provide.Strategy); older kubo
    // calls it Reprovider.Strategy. Re-resolve with `docker buildx imagetools inspect ipfs/kubo:latest`.
    kubo: {
      fullyQualifiedRepository: "ipfs/kubo",
      defaultDigest: { hash: "sha256:8907cb0cc1ad5798f6bb1bb1341a800990c268e021cedfa317e8aa1a33864214", tagHint: "v0.42.0" },
    },
    // Minimal OpenSSH SFTP-only server. The :alpine tag is a single-arch (linux/amd64) manifest --
    // matches methanol -- so the digest below is that manifest, not a multi-arch index.
    "atmoz-sftp": {
      fullyQualifiedRepository: "docker.io/atmoz/sftp",
      defaultDigest: { hash: "sha256:a6cb3eb29202ca7f57e73bb7e527286e66e0e822fff65609207c7e0ef2d135a3", tagHint: "alpine" },
    },
    // traefik/whoami is shared by the two tailscale-operator smoke tests at the same digest;
    // one digestFor<Consumer> per consumer, following the per-consumer convention.
    whoami: {
      fullyQualifiedRepository: "traefik/whoami",
      digestForTailscaleOperatorIngressTest: { hash: "sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab" },
      digestForTailscaleOperatorNetworkL3Test: { hash: "sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab" },
    },
    // Third-party images that lack a digest pin: migrated off inline tag strings, one tag each.
    "calibre-web-automated": {
      fullyQualifiedRepository: "docker.io/crocodilestick/calibre-web-automated",
      defaultTag: "latest",
    },
    "ddns-updater": {
      fullyQualifiedRepository: "qmcgaw/ddns-updater",
      defaultTag: "latest",
    },
    "http-echo": {
      fullyQualifiedRepository: "hashicorp/http-echo",
      defaultTag: "latest",
    },
    openclaw: {
      fullyQualifiedRepository: "ghcr.io/openclaw/openclaw",
      defaultTag: "2026.6.1",
    },
    // busybox is shared as an init/helper image across several services, pinned at different
    // versions; one tag per consumer rather than a single default.
    busybox: {
      fullyQualifiedRepository: "busybox",
      tagForOpenclaw: "1.37",
      tagForQbittorrent: "1.37",
      tagForThelounge: "1.37",
      tagForKataMicrovmTest: "1.36",
      tagForExampleZfs: "1.36",
    },
  },
  embellished: {
    local prev = this.raw[field],
    [field]: prev + {
      [if std.objectHas(prev, "defaultDigest") then "fullyQualifiedImageReferencePinned"]: pinnedRef(prev.fullyQualifiedRepository, prev.defaultDigest),
      [if std.objectHas(prev, "defaultTag") then "fullyQualifiedImageReferenceTagged"]: taggedRef(prev.fullyQualifiedRepository, prev.defaultTag),
      [if std.objectHas(prev, "tagForOpenclaw") then "fullyQualifiedImageReferenceTaggedForOpenclaw"]: taggedRef(prev.fullyQualifiedRepository, prev.tagForOpenclaw),
      [if std.objectHas(prev, "tagForQbittorrent") then "fullyQualifiedImageReferenceTaggedForQbittorrent"]: taggedRef(prev.fullyQualifiedRepository, prev.tagForQbittorrent),
      [if std.objectHas(prev, "tagForThelounge") then "fullyQualifiedImageReferenceTaggedForThelounge"]: taggedRef(prev.fullyQualifiedRepository, prev.tagForThelounge),
      [if std.objectHas(prev, "tagForKataMicrovmTest") then "fullyQualifiedImageReferenceTaggedForKataMicrovmTest"]: taggedRef(prev.fullyQualifiedRepository, prev.tagForKataMicrovmTest),
      [if std.objectHas(prev, "tagForExampleZfs") then "fullyQualifiedImageReferenceTaggedForExampleZfs"]: taggedRef(prev.fullyQualifiedRepository, prev.tagForExampleZfs),
      [if std.objectHas(prev, "digestForTailscaleOperatorIngressTest") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest"]: pinnedRef(prev.fullyQualifiedRepository, prev.digestForTailscaleOperatorIngressTest),
      [if std.objectHas(prev, "digestForTailscaleOperatorNetworkL3Test") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test"]: pinnedRef(prev.fullyQualifiedRepository, prev.digestForTailscaleOperatorNetworkL3Test),
    }
    for field in std.objectFields(this.raw)
  },
  public: {
    local prev = this.embellished[field],
    [field]: {
      [if std.objectHas(prev, "fullyQualifiedImageReferencePinned") then "fullyQualifiedImageReferencePinned"]: prev.fullyQualifiedImageReferencePinned,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTagged") then "fullyQualifiedImageReferenceTagged"]: prev.fullyQualifiedImageReferenceTagged,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForOpenclaw") then "fullyQualifiedImageReferenceTaggedForOpenclaw"]: prev.fullyQualifiedImageReferenceTaggedForOpenclaw,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForQbittorrent") then "fullyQualifiedImageReferenceTaggedForQbittorrent"]: prev.fullyQualifiedImageReferenceTaggedForQbittorrent,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForThelounge") then "fullyQualifiedImageReferenceTaggedForThelounge"]: prev.fullyQualifiedImageReferenceTaggedForThelounge,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForKataMicrovmTest") then "fullyQualifiedImageReferenceTaggedForKataMicrovmTest"]: prev.fullyQualifiedImageReferenceTaggedForKataMicrovmTest,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForExampleZfs") then "fullyQualifiedImageReferenceTaggedForExampleZfs"]: prev.fullyQualifiedImageReferenceTaggedForExampleZfs,
      [if std.objectHas(prev, "fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest"]: prev.fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest,
      [if std.objectHas(prev, "fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test"]: prev.fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test,
    }
    for field in std.objectFields(this.embellished)
  },
};
images.public
