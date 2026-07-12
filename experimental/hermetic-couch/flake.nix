{
  description = "hermetic-couch — declarative games on nix-darwin (Apple Silicon)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    (flake-utils.lib.eachSystem [ "aarch64-darwin" ] (
      system:
      let
        # Self-permit only hermetic-couch's own captured game payloads (the user's owned
        # copies, tagged in meta) — they're marked unfree so they're never cache-pushed,
        # but `nix run .#<game>` shouldn't need NIXPKGS_ALLOW_UNFREE + --impure each launch.
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: pkg.meta.hermeticCouchCaptured or false;
        };
        lib = pkgs.lib;

        hcLib = import ./lib { inherit pkgs lib; };
        runners = import ./runners { inherit pkgs lib hcLib; };
        love = pkgs.callPackage ./pkgs/love.nix { };

        # Shared wine env for the provision/capture tools (same pin the wine runner uses).
        winePin = import ./lib/wine-pin.nix;
        whiskyWine = pkgs.callPackage ./pkgs/whisky-wine.nix { } winePin;
        winetricksMin = pkgs.callPackage ./pkgs/winetricks-min.nix { } {
          version = "20260125";
          hash = "sha256-Qx+C/HQADmyGRAnx2PtJXWlsA5KICOPorP/EUXkxKns=";
        };
        # slug → { appId; folder; } for every wine game, so hc-capture knows a game's
        # static Steam facts from just its slug (no per-game re-typing).
        wineCaptureTable = lib.mapAttrs' (
          attr: s:
          lib.nameValuePair (s.gameName or attr) {
            appId = s.runnerConfig.steamAppId or null;
            folder = s.runnerConfig.gameFolder or (s.gameName or attr);
          }
        ) (lib.filterAttrs (_: s: (s.runner or null) == "wine") specs);

        tools = {
          hc-steam-provision = pkgs.callPackage ./pkgs/tools/hc-steam-provision.nix {
            inherit whiskyWine;
            winetricks = winetricksMin;
          };
          hc-capture = pkgs.callPackage ./pkgs/tools/hc-capture.nix { games = wineCaptureTable; };
        };

        # Game specs. Flat output names (no packages.games.* nesting — that breaks
        # `nix flake check`); the home-manager module keeps the games.<name> namespace.
        specs = {
          love-hello = import ./games/love-hello.nix {
            inherit
              pkgs
              lib
              love
              hcLib
              ;
          };
          minecraft-sodium = import ./games/minecraft-sodium.nix { inherit pkgs lib hcLib; };
          meccha-chameleon = import ./games/meccha-chameleon.nix { inherit pkgs lib hcLib; };
        };
        built = lib.mapAttrs (name: spec: hcLib.mkGame { inherit name spec runners; }) specs;
      in
      {
        packages =
          (lib.mapAttrs (_: g: g.launcher) built)
          // (lib.mapAttrs' (name: g: lib.nameValuePair "${name}-app" g.app) built)
          // tools;

        apps =
          (lib.mapAttrs (_: g: flake-utils.lib.mkApp { drv = g.launcher; }) built)
          // (lib.mapAttrs (_: drv: flake-utils.lib.mkApp { inherit drv; }) tools);

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nixfmt-rfc-style
            pkgs.jq
          ];
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    ))
    // {
      homeManagerModules.default = import ./module.nix;
    };
}
