# Use import to use this file.
# This file cannot use `config`, because we cannot assume whether this module is being used from home-manager or otherwise.
{ lib, ...}:
let
  mkRelativePathStringsForMachine = machine: {
    ${machine} = lib.fix (selfRelativePathStrings: {
      # MUT: List all `everythingRepo` values for each machine here.
      everythingRepo = {
        "sodium" = "src/everything";
      }.${machine};

      venus = "${selfRelativePathStrings.everythingRepo}/venus";

      whale-digests = "${selfRelativePathStrings.everythingRepo}/exports/whale/digests";

      home = ""; # The home directory is an empty relative path to itself.
    });
  };
in
lib.fix (self: {
  # Home-relative path strings.
  # The top-level attributes are all machine names.
  # The top-level values are arbitrarily-deep attrsets that contain relative path strings.
  relativePathStrings = lib.mergeAttrsList [
    (mkRelativePathStringsForMachine "sodium")
  ];

  # MUT: Add any constants here
})