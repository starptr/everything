# Runner adapter registry. Each adapter is a function `spec -> { package, launchCmd,
# reconcile?, runtimeInputs? }` consumed by lib/mkGame.nix.
{
  pkgs,
  lib,
  hcLib,
}:
{
  native = import ./native.nix { inherit pkgs lib hcLib; };
  love2d = import ./love2d.nix { inherit pkgs lib hcLib; };
  java = import ./java.nix { inherit pkgs lib hcLib; };
}
