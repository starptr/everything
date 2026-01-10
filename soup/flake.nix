{
  description = "My personal NUR repository";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nixpkgs-devenv.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs-devenv";
    };
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    love = {
      url = "https://github.com/love2d/love/releases/download/11.5/love-11.5-macos.zip";
      flake = false;
    };
    jujutsu = {
      url = "github:jj-vcs/jj/v0.36.0";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    claude-code-overlay = {
      url = "github:ryoppippi/claude-code-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    chaseln = {
      url = "github:starptr/chaseln";
      inputs = {
        nixpkgs.follows = "nixpkgs-devenv";
        devenv.follows = "devenv";
      };
    };
    dark-notify = {
      url = "github:starptr/dark-notify";
      inputs = {
        nixpkgs.follows = "nixpkgs-devenv";
        devenv.follows = "devenv";
        fenix.follows = "fenix";
      };
    };
    check-gits = {
      url = "github:starptr/check-gits";
      inputs = {
        nixpkgs.follows = "nixpkgs-devenv";
        devenv.follows = "devenv";
      };
    };
  };

  nixConfig = {
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "ryoppippi.cachix.org-1:b2LbtWNvJeL/qb1B6TYOMK+apaCps4SCbzlPRfSQIms="
    ];
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
      "https://ryoppippi.cachix.org"
    ];
  };

  outputs = { self, nixpkgs, ... } @ inputs:
    let
      systems = [
        "x86_64-linux"
        "i686-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "aarch64-linux"
        "armv6l-linux"
        "armv7l-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      # TODO: remove in favor of `exports`
      flake-inputs = {
        inherit (inputs) love chaseln dark-notify fenix check-gits jujutsu claude-code-overlay;
      };
      # List of flake inputs that we want to transparently re-export (i.e. without custom packaging)
      exports = import ./exports.nix;
      # An attrset of each flake's canonical name to its default package
      default-packages = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          # List of all of the flake inputs that are packages we want to re-export
          flakes = builtins.attrValues
            # Only keep the inputs that are listed in `exports`
            (lib.filterAttrs (input-name: v: (builtins.elem input-name exports)) inputs);
          # Converts a flake into a flake tagged with its canonical name
          extendCanonicalName = flake: {
            # TODO: Expose `pname` in the upstream derivation, since `name` includes the flake's version
            name = flake.packages.${system}.default.input.pname;
            value = flake.packages.${system}.default;
          };
        in
          # Transposes the list of name-value attrsets into one name:value attrset
          builtins.listToAttrs (map extendCanonicalName flakes);
    in
    {
      # Debug values
      #exports = exports;
      #inputs = inputs;
      # ^ Debug values
      legacyPackages = forAllSystems (system:
        (default-packages system)
        // (import ./extraPackages.nix {
          inherit system;
          maybe-flake-inputs = flake-inputs;
          pkgs = import nixpkgs { inherit system; };
        })
      );
      #packages = forAllSystems (system: nixpkgs.lib.filterAttrs (_: v: nixpkgs.lib.isDerivation v) self.legacyPackages.${system});
      overlays = import ./overlays { maybe-flake-inputs = flake-inputs; };
    };
}
