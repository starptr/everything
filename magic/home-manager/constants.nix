# Use import to use this file.
{ config, lib, ...} @ inputs:
let
  constants = import ./../common/constants.nix (inputs);
in
{
  absolutePathStrings = lib.mapAttrs (machine: relativePathStrings:
    lib.mapAttrsRecursive (path: relativePathString:
      # MUT: List all expected home directories for each machine here.
      assert config.home.homeDirectory == {
        "sodium" = "/Users/yuto";
      }.${machine} || throw "Machine ${machine} did not have an expected home directory path.";
      "${config.home.homeDirectory}/${relativePathString}"
    ) relativePathStrings
  ) constants.relativePathStrings;
}