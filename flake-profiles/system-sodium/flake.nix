{
  description = "Yuto's system profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-firefox-darwin = {
      url = "github:bandithedoge/nixpkgs-firefox-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    jellyfin-mpv-shim-darwin = {
      url = "github:starptr/jellyfin-mpv-shim.nix";
      ##inputs.nixpkgs.follows = "nixpkgs"; # TODO: migrate to support new shim
    };

    systems.url = "github:nix-systems/default"; # For soup
    soup = {
      url = "github:starptr/soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs"; # Does not need to be devenv's nixpkgs, since we don't use soup's devshell
        systems.follows = "systems";
        devenv.follows = "devenv";
      };
    };
    # TODO: remove these by removing them from soup
    # TODO: move soup into this monorepo
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
    ];
  };

  outputs = inputs: (import ../outputs.nix) inputs;
}
