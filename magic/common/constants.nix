# Use import to use this file.
# This file cannot use `config`, because we cannot assume whether this module is being used from home-manager or otherwise.
{ lib, ...}:
lib.fix (self: let
  mkRelativePathStringsForMachine = machine: {
    ${machine} = lib.fix (selfRelativePathStrings: {
      everythingRepo = {
        # MUT: List all `everythingRepo` values for each machine here.
        "sodium" = "src/everything";
      }.${machine};

      venus = "${selfRelativePathStrings.everythingRepo}/venus";

      jupiter-dotenv = "${selfRelativePathStrings.everythingRepo}/${self.jupiter-env-path-rel-to-everythingRepo}";

      whale-digests = "${selfRelativePathStrings.everythingRepo}/exports/whale/digests";

      home = ""; # The home directory is an empty relative path to itself.
    });
  };
in {
  # Home-relative path strings.
  # The top-level attributes are all machine names.
  # The top-level values are arbitrarily-deep attrsets that contain relative path strings.
  relativePathStrings = lib.mergeAttrsList [
    (mkRelativePathStringsForMachine "sodium")
  ];

  # MUT: Add any constants here
  jupiter-env-path-rel-to-everythingRepo = "jupiter/.env";
})