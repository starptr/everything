{
    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
        systems.url = "github:nix-systems/default";
    };
    outputs = { self, ... } @ inputs: let
        forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
    in {
        packages = forEachSystem (system: let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
        in {
            graceful-shutdown = pkgs.python3Packages.buildPythonPackage {
                pname = "graceful-shutdown";
                version = "0.1.0";
                src = ./src;
                propagatedBuildInputs = [
                    pkgs.python3Packages.kubernetes
                ];
            };
        });
    };
}