# Set mpv config
{ config, pkgs, lib, ... }:
{
  imports = [
    ./venus-location.nix
  ];
  options = {
    venus.use-mpv.enableDarwinAppBundleWorkaround = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = ''
        Enable a workaround for the broken application bundle caused by the mpv-unwrapped wrapper.
        See https://github.com/NixOS/nixpkgs/issues/366964
      '';
    };
    venus.use-mpv.enableHotfileConfig = lib.mkOption {
      default = true;
      type = lib.types.bool;
      description = ''
        Use OOSS to expose hot-file configuration for mpv.
      '';
    };
  };
  config = let
    mpv-scripts = [
      pkgs.mpvScripts.mpv-webm
    ];
  in lib.mkMerge [
    {
      programs.mpv = {
        enable = true;
        # Let's try using hot-files
        #config = {
        #  vo = "gpu-next";
        #  target-colorspace-hint = "yes";
        #};
        #bindings = {
        #  "CTRL+1" = "show-text target-peak";
        #  "CTRL+2" = "apply-profile upscale-sdr-to-hdr";
        #  "CTRL+SHIFT+2" = "apply-profile upscale-sdr-to-hdr restore";
        #};
        #profiles = {
        #  "upscale-sdr-to-hdr" = {
        #    profile-desc = "Upscale SDR to HDR";
        #    profile-restore = "copy";
        #    tone-mapping = "spline";
        #    inverse-tone-mapping = "yes";
        #  };
        #};
        package = lib.mkDefault (pkgs.mpv-unwrapped.wrapper {
          mpv = pkgs.mpv-unwrapped.override { ffmpeg = pkgs.ffmpeg-full; };
          scripts = mpv-scripts;
        });
        scriptOpts = {
          webm = {
            output_directory = "~/Downloads";
            output_template = "%T";
          };
        };
      };
    }
    (lib.mkIf config.venus.use-mpv.enableDarwinAppBundleWorkaround {
      programs.mpv.package = pkgs.mpv-unwrapped;
      xdg.configFile = let
        configs = {
          "mpv/scripts/webm.lua".source = "${pkgs.mpvScripts.mpv-webm}/share/mpv/scripts/webm.lua";
        };
      in
      (lib.throwIf
        (builtins.length (builtins.attrNames configs) != builtins.length mpv-scripts)
        # If I forget to update one of the lists causing the lengths to be different, I want to know.
        "Darwin mpv scripts list is differently sized from the canonical list of mpv scripts"
        configs);
    })
    (lib.mkIf config.venus.use-mpv.enableHotfileConfig {
      xdg.configFile."mpv/mpv.conf".source = config.venus.ooss-maker-for-this-system "mpv/mpv.conf";
      xdg.configFile."mpv/input.conf".source = config.venus.ooss-maker-for-this-system "mpv/input.conf";
    })
  ];
}
