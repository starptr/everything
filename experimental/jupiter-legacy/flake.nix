{
  inputs = {
    systems.url = "github:nix-systems/default";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };
  outputs = { self, nixpkgs, devenv, systems, pyproject-nix } @ inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
      build-dns-config-pyproject = pyproject-nix.lib.project.loadPyproject {
        projectRoot = ./app;
      };
      getPythonPkg = pkgs: pkgs.python312;
      metadata = builtins.fromTOML (builtins.readFile ./app/pyproject.toml);
    in {
      packages = forEachSystem (system: let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        devenv-up = self.devShells.${system}.default.config.procfileScript;
        devenv-test = self.devShells.${system}.default.config.test;
        ${metadata.project.name} = let
          python = getPythonPkg pkgs;
          attrs = build-dns-config-pyproject.renderers.buildPythonPackage {
            inherit python;
          };
        in
        python.pkgs.buildPythonPackage (attrs);
      });
      
      devShells = forEachSystem
       (system:
          let
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          in
          {
            using-devenv = devenv.lib.mkShell {
              inherit inputs pkgs;
              modules = [
                {
                  packages = [
                    pkgs.hello
                  ];
                  enterShell = ''
                    hello
                  '';

                  languages.python = {
                    enable = true;
                    package = getPythonPkg pkgs;
                    venv = {
                      enable = true;
                      #requirements = ./requirements.txt;
                      requirements = ./requirements-freeze.txt;
                    };
                  };
                }
              ];
            };
            setup-venv = pkgs.mkShell {
              buildInputs = [
                (getPythonPkg pkgs)
              ];
            };
            default = self.devShells.${system}.using-devenv;
          }
       );
    };
}