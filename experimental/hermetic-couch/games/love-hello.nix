# Trivial in-repo LÖVE game — proves the Part 0 core pipeline (build → launcher → .app
# → nix run) with no network fetch and no account required.
{
  pkgs,
  lib,
  love,
  hcLib,
}:
let
  gameSrc = pkgs.runCommand "love-hello-src" { } ''
    mkdir -p $out
    cp ${./love-hello/main.lua} $out/main.lua
  '';
in
{
  runner = "love2d";
  displayName = "Love Hello";
  runnerConfig = { inherit love gameSrc; };
}
