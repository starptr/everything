{ pkgs, lib }: let
  yaml-lib = pkgs.callPackage ../lib/yaml.nix {};
in {
  config-directory = let
    generated = builtins.fromJSON (builtins.readFile ./../exports/jupiter/generated.json);
    configurations-by-file = lib.fix (self: {
      "andref.app.yaml" = import ./per-domain/andref.app.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "yart.me.yaml" = import ./per-domain/yart.me.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "yut.to.yaml" = import ./per-domain/yut.to.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "yuto.ink.yaml" = import ./per-domain/yuto.ink.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "yuto.sh.yaml" = import ./per-domain/yuto.sh.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "yuto.tel.yaml" = {};
      "yuto.wiki.yaml" = import ./per-domain/yuto.wiki.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "production.yaml" = {
        providers = {
          config = {
            class = "octodns.provider.yaml.YamlProvider";
            directory = "."; # This means that our CWD must be the directory containing these files
            default_ttl = 3600;
            enforce_order = false;
          };
          cloudflare = {
            class = "octodns_cloudflare.CloudflareProvider";
            token = "env/CLOUDFLARE_TOKEN";
            min_ttl = 60;
          };
        };
        zones = {
          # This is a dynamic zone config. The source(s), here `config`, will be
          # queried for a list of zone names and each will dynamically be set up to
          # match the dynamic entry.
          "yart.me." = {
            sources = [ "config" ];
            targets = [ "cloudflare" ];
          };
          "yuto.ink." = self."production.yaml".zones."yart.me.";
          "yuto.sh." = self."production.yaml".zones."yart.me.";
          "yuto.tel." = self."production.yaml".zones."yart.me.";
          "yuto.wiki." = self."production.yaml".zones."yart.me.";
          "yut.to." = self."production.yaml".zones."yart.me.";
          "andref.app." = self."production.yaml".zones."yart.me.";
        };
      };
    });
    configuration-files = builtins.mapAttrs (key: value:
      pkgs.writeTextFile {
        name = key;
        text = yaml-lib.toYAML value;
      }
    ) configurations-by-file;
    folder-containing-all-files = pkgs.runCommand "octodns-config" {} ''
      mkdir -p $out
      ${lib.concatMapAttrsStringSep "\n" (filename: file: ''
        ln -s ${file} $out/${filename}
      '') configuration-files}
    '';
  in folder-containing-all-files;
}