local digests = {
  local this = self,
  /**
   * For each image, we have a dictionary of relevant data.
   * - fullyQualifiedRepository: the repository part of the image reference, without tag or digest.
   * - defaultDigestForImageParameter: the digest string to use as the default pin for the `image` parameter commonly accepted by a `new()` constructor for instantiating the service.
   * - fullyQualifiedImageReference: the fully qualified image reference with the digest, i.e. "docker.io/yuto7/mopidy@sha256:abc123...". This is what should be used in the `image` field of the container spec for maximum immutability and reproducibility.
   *
   * Digests are read from exports/whale/digests/<name>.txt (written by
   * `nix run ./flake-profiles/whale#whale-push-<name>`), resolved via the
   * vendor/exports -> ../../exports jpath symlink. std.trim handles digest files
   * with or without a trailing newline.
   */
  raw: {
    mopidy: {
      fullyQualifiedRepository: "docker.io/yuto7/mopidy",
      defaultDigestForImageParameter: std.trim(importstr "exports/whale/digests/mopidy.txt"),
    },
    "example-image": {
      fullyQualifiedRepository: "docker.io/yuto7/example-image",
      defaultDigestForImageParameter: std.trim(importstr "exports/whale/digests/example-image.txt"),
    },
  },
  embellished: {
    local prev = this.raw[field],
    [field]: prev + {
      fullyQualifiedImageReference: prev.fullyQualifiedRepository + "@" + prev.defaultDigestForImageParameter,
    }
    for field in std.objectFields(this.raw)
  },
  public: {
    local prev = this.embellished[field],
    [field]: {
      fullyQualifiedImageReference: prev.fullyQualifiedImageReference,
    }
    for field in std.objectFields(this.embellished)
  },
};
digests.public
