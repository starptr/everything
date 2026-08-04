# Use import to use this file.
# This file cannot use `config`, because we cannot assume whether this module is being used from home-manager or otherwise.
{ lib, ...}:
lib.fix (self: let
  mkRelativePathStringsForMachine = machine: let
    # PRIVATE: not a relativePathStrings attribute. Silverwood makes the everything-repo
    # checkout location vary, so nothing may depend on a single canonical checkout path.
    # Kept only to feed `venus` below, which has no silverwood-safe source yet.
    everythingRepo = {
      # MUT: List all `everythingRepo` values for each machine here.
      "sodium" = "src/everything";
    }.${machine};
  in {
    ${machine} = lib.fix (selfRelativePathStrings: {
      home = ""; # The home directory is an empty relative path to itself.

      # Stopgap pin to the primary checkout: the ooss hot-file symlinks (venus/hot-files)
      # need a fixed absolute path at activation and have no silverwood-safe source yet.
      venus = "${everythingRepo}/venus";

      # Home-relative sops decryption store. Decrypted secrets live here (outside any
      # checkout); consumers needing them in-tree bridge them in per-checkout themselves.
      secrets = ".config/sops-nix/secrets";
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

  # Reusable public keys (SSH). Single source of truth: ./public_keys.json.
  publicKeys = builtins.fromJSON (builtins.readFile ./public_keys.json);
})