# hermetic-couch core library. Returns the composable builders used by the flake
# and the home-manager module. `mkGame` receives `runners` at call time (not baked
# in here) to avoid a lib<->runners import cycle.
{ pkgs, lib }:
let
  self = {
    reconcile = import ./reconcile.nix { inherit pkgs lib; };
    versions = import ./versions.nix { inherit pkgs lib; };
    mkAppBundle = import ./mkAppBundle.nix { inherit pkgs lib; };
    fetchMod = import ./fetch-mod.nix { inherit pkgs lib; };
    mkGame = import ./mkGame.nix {
      inherit pkgs lib;
      hcLib = self;
    };
  };
in
self
