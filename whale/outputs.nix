{ self, nixpkgs, ... } @ inputs: let
  forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
in {
  packages = forEachSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      example-image = pkgs.dockerTools.buildLayeredImage {
        name = "example-image";
        tag = "latest";
        contents = [ pkgs.curl ]; # Replace with your app
        config.Cmd = [ "curl" "--version" ];
      };
      make-push-script = { layeredImage, name }: pkgs.writeShellApplication {
        name = "push-${name}";
        # We have to use skopeo; docker CLI requires the docker daemon to be running.
        runtimeInputs = [ pkgs.skopeo pkgs.jq pkgs.docker-credential-helpers ];
        text = ''
          set -euo pipefail

          dest="docker://docker.io/yuto7/${name}:latest"

          echo "Checking credentials..."
          if [[ -f "$HOME/.config/containers/auth.json" ]]; then
            echo "Using creds from ~/.config/containers/auth.json"
          else
            echo "Error: No credentials found."
            echo "Login with 'skopeo login docker.io'. You can use 'nix-shell -p skopeo' to get the skopeo command."
            exit 1
          fi

          echo "Pushing to $dest..."
          skopeo copy "docker-archive:${layeredImage}" "$dest"
          echo "Done!"
        '';
      };
    in {
      whale-push-example = make-push-script {
        layeredImage = example-image;
        name = "example-image";
      };
      whale-example-image = example-image;
    });
}