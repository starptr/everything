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

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    soup = {
      url = "github:starptr/soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs";
        systems.follows = "systems";
      };
    };
  };

  outputs = { self, ... } @ inputs: let
    forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
    generated = builtins.fromJSON (builtins.readFile ./../../exports/jupiter/generated.json);
  in {
    devShells = forEachSystem (system: let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
    in {
      deploy = pkgs.mkShell {
        buildInputs = [
          pkgs.deploy-rs
        ];
      };
      default = self.devShells.${system}.deploy;
    });

    nixosConfigurations.ethane = inputs.nixpkgs.lib.nixosSystem {
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
        ./../../venus/modules/nixos-darwin/ethane.nix
      ];
    };

    deploy.nodes.ethane = {
      hostname = generated.ethane.ipAddress;
      profilesOrder = [ "system" ];
      profiles.system = {
        user = "root";
        sshUser = "root";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.ethane;
        remoteBuild = true;
      };
    };

    # This is highly advised, and will prevent many possible mistakes
    # Disabled to avoid remote builder
    #checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
  };
}