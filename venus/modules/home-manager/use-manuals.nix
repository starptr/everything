# This builds manual pages for the current intance of nixpkgs
{ nixpkgs, pkgs, ... }:
{
  config = {
    home.file."nix-manuals/nixos-release".source = "${(import "${nixpkgs}/nixos/release.nix" { inherit nixpkgs; }).manualHTML.x86_64-linux}/share/doc/nixos";
    home.file."nix-manuals/nixpkgs-manual".source = "${pkgs.nixpkgs-manual.override { inherit nixpkgs; }}/share/doc/nixpkgs";
  };
}