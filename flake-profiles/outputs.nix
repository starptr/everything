{
  self,
  ...
} @ inputs:
let
  # Define common variables
  forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
  recursiveUpdateAll = builtins.foldl' inputs.nixpkgs.lib.recursiveUpdate {};
in
# TODO: replace with recursiveUpdateAllNoOverlap (fails if there is conflict)
recursiveUpdateAll [
  {
    # Jupiter
    # TODO: split up Jupiter into 2 projects: pulumi and build-dns-config
    devShells = forEachSystem (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        getPython = pkgs: pkgs.python312;
      in
      {
        # `nix develop flake-profiles/everything-devenv#jupiter`
        jupiter = inputs.devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              packages = [
                pkgs.hello
                pkgs.pulumi-bin
              ];
              enterShell = ''
                hello
              '';

              languages.python = {
                enable = true;
                package = getPython pkgs;
                venv = {
                  enable = true;
                  #requirements = ./requirements.txt;
                  requirements = ./../jupiter/requirements-freeze.txt;
                };
              };
            }
          ];
        };
      });
    packages = forEachSystem (system: let
      # TODO: forEachSystem should be around the entire Jupiter section of the outputs
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      getPython = pkgs: pkgs.python312;
      build-dns-config-pyproject = inputs.pyproject-nix.lib.project.loadPyproject {
        projectRoot = ./../jupiter/app;
      };
      metadata = builtins.fromTOML (builtins.readFile ./../jupiter/app/pyproject.toml);
    in
    {
      # `nix run flake-profiles/build-dns-config#build-dns-config`
      ${metadata.project.name} = let
        python = getPython pkgs;
        attrs = build-dns-config-pyproject.renderers.buildPythonPackage {
          inherit python;
        };
      in
      python.pkgs.buildPythonPackage (attrs);
    });
  }
  {
    # Main

    devShells = forEachSystem (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
      in
      {
        default = inputs.devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              # https://devenv.sh/reference/options/
              packages = [
                pkgs.hello
                pkgs.sops
                pkgs.ssh-to-age
              ];
  
              enterShell = ''
                hello
                echo "Reminder: Do not use git in this repo. Use jujutsu instead."
                echo "Don't forget to run `jj new` before making a new change."
              '';
  
              processes.hello.exec = "hello";
  
              languages.nix.enable = true;
            }
          ];
        };
      });
  
    darwinConfigurations."Yutos-Sodium" = inputs.nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ../venus/modules/nixos-darwin/sodium.nix
        inputs.home-manager.darwinModules.home-manager
        {
          nixpkgs = {
            overlays = [
              (self: super: {
                jellyfin-mpv-shim = inputs.jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
              })
              #chaseln.overlays.chaseln
              inputs.soup.overlays.chaseln
              (final: super: {
                check-gits = inputs.soup.legacyPackages."aarch64-darwin".check-gits;
              })
            ];
            config = import ../venus/app-configs/nixpkgs-config.nix; # Configures pkgs for evaluating this darwinConfiguration ("buildtime" config)
          };
        }
        {
          home-manager.useGlobalPkgs = true;
          #home-manager.useUserPackages = true; # This breaks fish??
          home-manager.users.yuto = {
            imports = [
              inputs.sops-nix.homeManagerModules.sops
              (import ../venus/modules/home-manager/sodium.nix)
            ];
          };
          home-manager.extraSpecialArgs = {
            inherit (inputs) nixpkgs;
          };
        }
      ];
    };
  }
]