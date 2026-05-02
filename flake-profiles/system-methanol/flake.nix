{
  inputs = {
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default";

    soup = {
      url = "path:./../../soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs"; # Does not need to be devenv's nixpkgs, since we don't use soup's devshell
        systems.follows = "systems";
        devenv.follows = "nixpkgs"; # TODO: remove devenv from soup
      };
    };
  };

  outputs = { self, ... } @ inputs: let
    forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
    generated = builtins.fromJSON (builtins.readFile ./../../exports/jupiter/generated.json);
  in {
    nixosConfigurations.methanol = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
        {
          nixpkgs = {
            overlays = [
              inputs.soup.overlays.chaseln
            ];
          };
        }
        ./../../venus/modules/nixos-darwin/methanol.nix
      ];
    };

    deploy.nodes.methanol = {
      hostname = "10.0.0.211"; # TODO: use mDNS local address
      profilesOrder = [ "system" ];
      profiles.system = {
        sshUser = "root";
        user = "root";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.methanol;
        remoteBuild = true;
      };
    };

    # This is highly advised, and will prevent many possible mistakes
    # Disabled to avoid remote builder
    #checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
  };
}