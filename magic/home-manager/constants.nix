# Use import to use this file.
{ config, lib, ...} @ inputs:
let
  constants = import ./../common/constants.nix (inputs);
in
{
  absolutePathStrings = lib.mapAttrs (machine: relativePathStrings:
    lib.mapAttrsRecursive (path: relativePathString:
      assert config.home.homeDirectory == {
        # MUT: List all expected home directories for each machine here.
        "sodium" = "/Users/yuto";
        "tilderef2-starptr" = "/home/starptr";
        "magnesium-hydroxide" = "/Users/yuto.nishida";
        "hydrogen-sulfide" = "/home/nixos";
      }.${machine} || throw "Machine ${machine} did not have an expected home directory path.";
      "${config.home.homeDirectory}/${relativePathString}"
    ) relativePathStrings
  ) constants.relativePathStrings;
}