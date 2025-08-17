# This file describes your repository contents.
# It should return a set of nix derivations
# and optionally the special attributes `lib`, `modules` and `overlays`.
# It should NOT import <nixpkgs>. Instead, you should take pkgs as an argument.
# Having pkgs default to <nixpkgs> is fine though, and it lets you use short
# commands such as:
#     nix-build -A mypackage

{ pkgs, maybe-flake-inputs }:
let
  flake-lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  callPackageWithMaybeFlakeInputs = pkgs.lib.callPackageWith (pkgs // {
    inherit maybe-flake-inputs flake-lock;
  });
in
{
  # The `lib`, `modules`, and `overlays` names are special
  #lib = import ./lib { inherit pkgs; }; # functions
  #modules = import ./modules; # NixOS modules
  #overlays = import ./overlays { inherit maybe-flake-inputs; }; # nixpkgs overlays

  #example-package = pkgs.callPackage ./pkgs/example-package { };
  # some-qt5-package = pkgs.libsForQt5.callPackage ./pkgs/some-qt5-package { };
  # ...
  love = callPackageWithMaybeFlakeInputs ./pkgs/love { };
}
