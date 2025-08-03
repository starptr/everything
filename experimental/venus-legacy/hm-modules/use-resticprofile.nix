# Set resticprofile options
{
  config,
  pkgs,
  lib,
  osConfig,
  ...
}:
{
  #options = {
  #  use-resticprofile.for-sodium = {
  #    default = false;
  #    type = lib.types.bool;
  #    description = ''
  #      Enable resticprofile configuration for Sodium.
  #    '';
  #  };
  #};
  config = {
    home.packages = [
      pkgs.resticprofile
    ];

    #xdg.configFile."resticprofile/profiles.toml".source = ../configs/restic-profile.toml;
    xdg.configFile."resticprofile/profiles.json".text = builtins.toJSON (lib.fix (self: {
      sources = {
        downloads = "${config.home.homeDirectory}/Downloads";
        ryujinx-appdata = "${config.home.homeDirectory}/Library/Application Support/Ryujinx";
        aaaaxy-appdata = "${config.home.homeDirectory}/Library/Application Support/AAAAXY";
        blue3ds-checkpoint-saves = "/Volumes/Blue3DS/3ds/Checkpoint";
        blue3ds-sdcard = "/Volumes/Blue3DS";
      };
      repositories = {
        main-restic-repo-via-s3 = "rclone:storj-baks:backup-repos/main-restic-backups";
        main-restic-repo-via-native = "rclone:storj-baks-native:backup-repos/main-restic-backups";
      };
      config-partials = {
        base = {
          exclude = [ "/**/.git" ];
          password-file = "password.txt";
          backup = {
            verbose = true;
          };
        };
      };
      config = {
        version = "1";
        default = lib.recursiveUpdate self.config-partials.base {
          repository = self.repositories.main-restic-repo-via-s3;
          backup.tag = [ "sodium" "ryujinx" "blue3ds-checkpoint" ];
          backup.source = [
            #self.sources.downloads # TODO: maybe add a new profile that includes downlaods
            self.sources.ryujinx-appdata
            self.sources.aaaaxy-appdata
            self.sources.blue3ds-checkpoint-saves
          ];
        };
        default-use-native = lib.recursiveUpdate self.config.default {
          repository = self.repositories.main-restic-repo-via-native;
        };
        ryujinx = lib.recursiveUpdate self.config-partials.base {
          repository = self.repositories.main-restic-repo-via-s3;
          backup.tag = [ "sodium" "ryujinx" ];
          backup.source = [
            self.sources.ryujinx-appdata
          ];
        };
        ryujinx-use-native = lib.recursiveUpdate self.config.ryujinx {
          repository = self.repositories.main-restic-repo-via-native;
        };
        blue3ds = lib.recursiveUpdate self.config-partials.base {
          repository = self.repositories.main-restic-repo-via-s3;
          backup.tag = [ "sodium" "blue3ds-checkpoint" "blue3ds" ];
          backup.source = [
            self.sources.blue3ds-sdcard
          ];
        };
        blue3ds-use-native = lib.recursiveUpdate self.config.blue3ds {
          repository = self.repositories.main-restic-repo-via-native;
        };
      };
    })).config;
  };
}
