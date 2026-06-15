local digests = {
  local this = self,

  // Render a pinned image reference from a digest object { hash, tagHint? }. The hash (e.g.
  // "sha256:abc...") is what's enforced; the optional tagHint (e.g. "v3.41.1") is folded in purely
  // for human readability -> "repo:tagHint@sha256:..." when present, "repo@sha256:..." otherwise.
  local pinnedRef(repository, digest) =
    repository + (if std.objectHas(digest, "tagHint") then ":" + digest.tagHint else "") + "@" + digest.hash,

  /**
   * For each image, we have a dictionary of relevant data.
   * - fullyQualifiedRepository: the repository part of the image reference, without tag or digest.
   * - defaultDigestForImageParameter: a digest object { hash, tagHint? } used as the default pin for the `image` parameter commonly accepted by a `new()` constructor for instantiating the service. `hash` is the immutable digest ("sha256:..."); the optional `tagHint` is a human-readable version tag folded into the rendered reference (NOT enforced -- the digest is).
   * - defaultTagForImageParameter: a tag string used as the default for the `image` parameter when no digest is available. DEPRECATED, only for migrating off inline tag strings.
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
      defaultDigestForImageParameter: { hash: std.trim(importstr "exports/whale/digests/mopidy.txt") },
    },
    "example-image": {
      fullyQualifiedRepository: "docker.io/yuto7/example-image",
      defaultDigestForImageParameter: { hash: std.trim(importstr "exports/whale/digests/example-image.txt") },
    },
    // Third-party images pinned by digest (the hash is enforced; tagHint is the readable version).
    gluetun: {
      fullyQualifiedRepository: "qmcgaw/gluetun",
      defaultDigestForImageParameter: { hash: "sha256:2f33c71e5e164fcd51a962cb950134df25155593edf0c3e1201f888d027049b4", tagHint: "v3.41.1" },
    },
    python: {
      fullyQualifiedRepository: "python",
      defaultDigestForImageParameter: { hash: "sha256:2d07747661646f3d904e995a232fb19e461afde69e67e6f7f3b52c7b968a88b3", tagHint: "3.12-alpine" },
    },
    qbittorrent: {
      fullyQualifiedRepository: "lscr.io/linuxserver/qbittorrent",
      defaultDigestForImageParameter: { hash: "sha256:1784d5a65d08d01de308c7d87ff2c1dba328379e180eeca41cc6b96bdf6a0ffc", tagHint: "5.2.1" },
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
      defaultTagForImageParameter: "latest",
    },
    "ddns-updater": {
      fullyQualifiedRepository: "qmcgaw/ddns-updater",
      defaultTagForImageParameter: "latest",
    },
    "http-echo": {
      fullyQualifiedRepository: "hashicorp/http-echo",
      defaultTagForImageParameter: "latest",
    },
    openclaw: {
      fullyQualifiedRepository: "ghcr.io/openclaw/openclaw",
      defaultTagForImageParameter: "2026.6.1",
    },
    // busybox is shared as an init/helper image across several services, pinned at different
    // versions; one tag per consumer rather than a single default.
    busybox: {
      fullyQualifiedRepository: "busybox",
      tagForOpenclaw: "1.37",
      tagForQbittorrent: "1.37",
      tagForKataMicrovmTest: "1.36",
      tagForExampleZfs: "1.36",
    },
  },
  embellished: {
    local prev = this.raw[field],
    [field]: prev + {
      [if std.objectHas(prev, "defaultDigestForImageParameter") then "fullyQualifiedImageReferencePinned"]: pinnedRef(prev.fullyQualifiedRepository, prev.defaultDigestForImageParameter),
      [if std.objectHas(prev, "defaultTagForImageParameter") then "fullyQualifiedImageReferenceTagged"]: prev.fullyQualifiedRepository + ":" + prev.defaultTagForImageParameter,
      [if std.objectHas(prev, "tagForOpenclaw") then "fullyQualifiedImageReferenceTaggedForOpenclaw"]: prev.fullyQualifiedRepository + ":" + prev.tagForOpenclaw,
      [if std.objectHas(prev, "tagForQbittorrent") then "fullyQualifiedImageReferenceTaggedForQbittorrent"]: prev.fullyQualifiedRepository + ":" + prev.tagForQbittorrent,
      [if std.objectHas(prev, "tagForKataMicrovmTest") then "fullyQualifiedImageReferenceTaggedForKataMicrovmTest"]: prev.fullyQualifiedRepository + ":" + prev.tagForKataMicrovmTest,
      [if std.objectHas(prev, "tagForExampleZfs") then "fullyQualifiedImageReferenceTaggedForExampleZfs"]: prev.fullyQualifiedRepository + ":" + prev.tagForExampleZfs,
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
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForKataMicrovmTest") then "fullyQualifiedImageReferenceTaggedForKataMicrovmTest"]: prev.fullyQualifiedImageReferenceTaggedForKataMicrovmTest,
      [if std.objectHas(prev, "fullyQualifiedImageReferenceTaggedForExampleZfs") then "fullyQualifiedImageReferenceTaggedForExampleZfs"]: prev.fullyQualifiedImageReferenceTaggedForExampleZfs,
      [if std.objectHas(prev, "fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest"]: prev.fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest,
      [if std.objectHas(prev, "fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test") then "fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test"]: prev.fullyQualifiedImageReferencePinnedForTailscaleOperatorNetworkL3Test,
    }
    for field in std.objectFields(this.embellished)
  },
};
digests.public
