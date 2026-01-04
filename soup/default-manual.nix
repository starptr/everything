# This file describes your repository contents.
# It should return a set of nix derivations
# and optionally the special attributes `lib`, `modules` and `overlays`.
# It should NOT import <nixpkgs>. Instead, you should take pkgs as an argument.
# Having pkgs default to <nixpkgs> is fine though, and it lets you use short
# commands such as:
#     nix-build -A mypackage

{ pkgs ? import <nixpkgs> { }, maybe-flake-inputs ? null }:
let
  flake-lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  callPackageWithMaybeFlakeInputs = pkgs.lib.callPackageWith (pkgs // {
    inherit maybe-flake-inputs flake-lock;
  });
  # List of flake inputs that we want to transparently re-export (i.e. without custom packaging)
  exports = import ./exports.nix;
in
{
  # The `lib`, `modules`, and `overlays` names are special
  lib = import ./lib { inherit pkgs; }; # functions
  modules = import ./modules; # NixOS modules
  overlays = import ./overlays { inherit maybe-flake-inputs; }; # nixpkgs overlays

  example-package = pkgs.callPackage ./pkgs/example-package { };
  # some-qt5-package = pkgs.libsForQt5.callPackage ./pkgs/some-qt5-package { };
  # ...
  love = callPackageWithMaybeFlakeInputs ./pkgs/love { };
  chaseln = callPackageWithMaybeFlakeInputs ./pkgs/chaseln.nix { };
  dark-notify = callPackageWithMaybeFlakeInputs ./pkgs/dark-notify.nix { };
  check-gits = callPackageWithMaybeFlakeInputs ./pkgs/check-gits.nix { };
}
