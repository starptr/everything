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
    in {
      whale-push-example =
      pkgs.writeShellApplication {
        name = "push-example";
        runtimeInputs = [ pkgs.skopeo pkgs.jq pkgs.docker-credential-helpers ];
        text = ''
          set -euo pipefail

          dest="docker://docker.io/yuto7/example-image:latest"

          echo "Checking credentials..."
          if [[ -n "''${REGISTRY_USER:-}" && -n "''${REGISTRY_PASS:-}" ]]; then
            echo "Using creds from environment variables"
            creds_opt=(--dest-creds "''${REGISTRY_USER}:''${REGISTRY_PASS}")
          elif [[ -f "$HOME/.docker/config.json" ]]; then
            echo "Using creds from ~/.docker/config.json"
            creds_opt=()
          else
            echo "Error: No credentials found."
            echo "Login with 'docker login registry.example.com' or set REGISTRY_USER and REGISTRY_PASS."
            exit 1
          fi

          #echo "Building OCI image..."
          #ociDir=$(mktemp -d)
          #cp -r ${example-image} "$ociDir"

          echo "Pushing to $dest..."
          skopeo copy "docker-archive:${example-image}" "$dest" "''${creds_opt[@]}"
          echo "Done!"
        '';
      };
      whale-example-image = example-image;
    });
}