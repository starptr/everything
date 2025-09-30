local digests = {
  local this = self,
  raw: {
    mopidy: importstr "../../../exports/whale/digests/mopidy.txt",
  },
  clean: {
    [field]: std.trim(this.raw[field])
    for field in std.objectFields(this.raw)
  },
  nickNameToFullyQualifiedName: {
    mopidy: "docker.io/yuto7/mopidy@" + this.clean.mopidy, 
  },
};
digests.nickNameToFullyQualifiedName