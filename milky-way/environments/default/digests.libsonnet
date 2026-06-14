local digests = {
  local this = self,
  /**
   * For each image, we have a dictionary of relevant data.
   * - fullyQualifiedRepository: the repository part of the image reference, without tag or digest.
   * - defaultDigestForImageParameter: the digest string to use as the default pin for the `image` parameter commonly accepted by a `new()` constructor for instantiating the service.
   * - fullyQualifiedImageReference: the fully qualified image reference with the digest, i.e. "docker.io/yuto7/mopidy@sha256:abc123...". This is what should be used in the `image` field of the container spec for maximum immutability and reproducibility.
   */
  raw: {
    mopidy: {
      fullyQualifiedRepository: "docker.io/yuto7/mopidy",
      defaultDigestForImageParameter: importstr "../../../exports/whale/digests/mopidy.txt",
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