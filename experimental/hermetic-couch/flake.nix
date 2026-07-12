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
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        hcLib = import ./lib { inherit pkgs lib; };
        runners = import ./runners { inherit pkgs lib hcLib; };
        love = pkgs.callPackage ./pkgs/love.nix { };

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
        };
        built = lib.mapAttrs (name: spec: hcLib.mkGame { inherit name spec runners; }) specs;
      in
      {
        packages =
          (lib.mapAttrs (_: g: g.launcher) built)
          // (lib.mapAttrs' (name: g: lib.nameValuePair "${name}-app" g.app) built);

        apps = lib.mapAttrs (_: g: flake-utils.lib.mkApp { drv = g.launcher; }) built;

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
