# home-manager module exposing `games.<name>` (an attrset of per-game submodules).
# Each enabled game becomes a launcher (+ .app bundle) added to home.packages. Not yet
# wired into any machine profile — integration into sodium.nix is Part 5. Options here
# mirror the game-spec shape consumed by lib/mkGame.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hcLib = import ./lib { inherit pkgs lib; };
  runners = import ./runners { inherit pkgs lib hcLib; };

  cfg = config.games;
  enabled = lib.filterAttrs (_: g: g.enable) cfg;
  built = lib.mapAttrs (
    name: g:
    hcLib.mkGame {
      inherit name runners;
      spec = g;
    }
  ) enabled;

  gameModule =
    { name, ... }:
    {
      options = {
        enable = (lib.mkEnableOption "the ${name} game") // {
          default = true;
        };
        runner = lib.mkOption {
          type = lib.types.enum [
            "native"
            "love2d"
            "java"
            "wine"
          ];
          description = "Which runner adapter scaffolds and launches this game.";
        };
        drm = lib.mkOption {
          type = lib.types.enum [
            "none"
            "steamStub"
            "machineBound"
          ];
          default = "none";
          description = "DRM behavior at launch (DESIGN §1); classifies the purity tier.";
        };
        displayName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Human-facing name (used for the .app bundle).";
        };
        runnerConfig = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Runner-specific configuration (see runners/<runner>.nix).";
        };
        gameName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Stable slug for captured payloads / tooling (defaults to the attr name).";
        };
        play = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Selected version to launch (keys into `versions`); DESIGN §4.";
        };
        versions = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          default = { };
          description = "Per-user version→{sha256;buildid} map from hc-capture (Pattern B).";
        };
        settings = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Declarative game settings, rendered to the game's config format.";
        };
        launch = lib.mkOption {
          type = lib.types.attrs;
          default = {
            args = [ ];
            env = { };
          };
          description = "Extra launch args and environment variables.";
        };
        instanceRel = lib.mkOption {
          type = lib.types.str;
          default = "hermetic-couch/${name}";
          description = "Mutable instance dir, relative to ~/Library/Application Support.";
        };
        icon = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Optional .icns for the generated .app bundle.";
        };
      };
    };
in
{
  options.games = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule gameModule);
    default = { };
    description = "Declarative games managed by hermetic-couch.";
  };

  config = lib.mkIf (enabled != { }) {
    home.packages =
      (lib.mapAttrsToList (_: g: g.launcher) built) ++ (lib.mapAttrsToList (_: g: g.app) built);
  };
}
