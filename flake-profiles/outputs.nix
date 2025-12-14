# This file is ... not a good idea, actually
# Instead of centralizing all outputs, we should have each flake-profile
# be its own flake-parts style flake.
# Projects that want to use other flake-profiles can implement their package
# logic in the flake-profile's flake.nix.
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
  # Eight
  ((import ./../eight/outputs.nix) inputs)
  {
    # Jupiter
    # TODO: split up Jupiter into 2 projects: pulumi and build-dns-config
    devShells = forEachSystem (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        getPython = pkgs: pkgs.python312;
        magic = pkgs.callPackage ./../magic/common/constants.nix {};
      in
      {
        # `nix develop ./flake-profiles/everything-devenv#jupiter --impure`
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
                # Automatically export environment variables from the .env file
                # We manually source the file instead of using the dotenv integration with devenv
                # because the env file is not checked into git. Therefore, at evaluation time,
                # the flake cannot read the file. Or at least this is my guess on why it doesn't work.
                if [ -f "${magic.jupiter-env-path-rel-to-everythingRepo}" ]; then
                  echo "Loading environment variables from ${magic.jupiter-env-path-rel-to-everythingRepo}"
                  source "${magic.jupiter-env-path-rel-to-everythingRepo}"
                else
                  echo "Warning: ${magic.jupiter-env-path-rel-to-everythingRepo} not found."
                fi
              '';

              languages.python = {
                enable = true;
                package = getPython pkgs;
                venv = {
                  enable = true;
                  #requirements = ./requirements.txt;
                  requirements = ./../jupiter/requirements.txt;
                };
              };
            }
          ];
        };
      });
    #packages = forEachSystem (system: let
    #  # TODO: forEachSystem should be around the entire Jupiter section of the outputs
    #  pkgs = inputs.nixpkgs.legacyPackages.${system};
    #  getPython = pkgs: pkgs.python312;
    #  build-dns-config-pyproject = inputs.pyproject-nix.lib.project.loadPyproject {
    #    projectRoot = ./../jupiter/app;
    #  };
    #  metadata = builtins.fromTOML (builtins.readFile ./../jupiter/app/pyproject.toml);
    #in
    #{
    #  # `nix run ./flake-profiles/build-dns-config#build-dns-config`
    #  ${metadata.project.name} = let
    #    python = getPython pkgs;
    #    attrs = build-dns-config-pyproject.renderers.buildPythonPackage {
    #      inherit python;
    #    };
    #  in
    #  python.pkgs.buildPythonPackage (attrs);
    #});
  }
  {
    # Main

    devShells = forEachSystem (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
      in
      {
        # `nix develop ./flake-profiles/everything-devenv#default --impure`
        default = inputs.devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              # https://devenv.sh/reference/options/
              packages = [
                pkgs.hello
                pkgs.sops
                pkgs.ssh-to-age
                pkgs.deploy-rs
              ];
  
              enterShell = ''
                hello
                echo "Reminder: Do not use git in this repo. Use jujutsu instead."
                echo "Don't forget to run 'jj new' before making a new change."
              '';
  
              processes.hello.exec = "hello";
  
              languages.nix.enable = true;
            }
          ];
        };
      });
  }
]