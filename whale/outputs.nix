{ self, nixpkgs, ... } @ inputs: let
  magic = import ./../magic/common/constants.nix inputs.nixpkgs;
  machine = "sodium"; # Current machine name
  digests-directory-home-relative-pathstr = magic.relativePathStrings.${machine}.whale-digests;
  forEachSystem = inputs.nixpkgs.lib.genAttrs ["x86_64-linux"];
in {
  packages = forEachSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      # Creates an attrset with two properties: the image and a script to push it to the docker registry.
      # @param name: The name of the docker repository for the image.
      # @param buildLayeredImageArg: The arguments to pass to `dockerTools.buildLayeredImage`. The `name` property is optional, but can be specified here too.
      image-nix-artifacts = { name, buildLayeredImageArg }: let
          image = pkgs.dockerTools.buildLayeredImage ({
            inherit name;
          } // buildLayeredImageArg);
          push-script = pkgs.writeShellApplication {
            name = "push-${name}";
            # We have to use skopeo; docker CLI requires the docker daemon to be running.
            runtimeInputs = [ pkgs.skopeo pkgs.jq pkgs.docker-credential-helpers ];
            text = ''
              set -euo pipefail

              dest="docker://docker.io/yuto7/${name}:latest"

              echo "Checking credentials..."
              if [[ -f "$XDG_RUNTIME_DIR/containers/auth.json" ]]; then
                echo "Using creds from $XDG_RUNTIME_DIR/containers/auth.json"
              elif [[ -f "$HOME/.config/containers/auth.json" ]]; then
                echo "Using creds from ~/.config/containers/auth.json"
              else
                echo "Error: No credentials found."
                echo "Login with 'skopeo login docker.io'. You can use 'nix-shell -p skopeo' to get the skopeo command."
                exit 1
              fi

              echo "Pushing to $dest..."
              skopeo --insecure-policy copy "docker-archive:${image}" "$dest"
              echo "Done!"

              echo "Saving digest to $HOME/${digests-directory-home-relative-pathstr}/${name}.txt ..."
              digest=$(skopeo inspect --raw "docker-archive:${image}" | jq -r '.config.digest')
              if [[ -z "$digest" ]]; then
                echo "Error: Failed to get digest."
                exit 1
              fi

              echo "Image digest: $digest"
              echo "$digest" > "$HOME/${digests-directory-home-relative-pathstr}/${name}.txt"
              echo "Digest written to $HOME/${digests-directory-home-relative-pathstr}/${name}.txt"
            '';
          };
        in {
          inherit image push-script;
        };
    in let
      example-artifacts = image-nix-artifacts {
        name = "example-image";
        buildLayeredImageArg = {
          tag = "latest";
          contents = [ pkgs.curl ];
          config.Cmd = [ "curl" "--version" ];
        };
      };
      mopidy = image-nix-artifacts {
        name = "mopidy";
        buildLayeredImageArg = {
          tag = "latest";
          contents = [
            pkgs.curl
            pkgs.dumb-init
            pkgs.gnupg

            pkgs.mopidy
            pkgs.mopidy-local
            pkgs.mopidy-mpd
            pkgs.mopidy-spotify
          ];
          config = {
            Cmd = ["mopidy"];
            ExposedPorts = {
              "6600" = {};
              "6680" = {};
            };
          };
        };
      };
    in {
      whale-example-image = example-artifacts.image;
      whale-push-example = example-artifacts.push-script;
      mopidy-image = mopidy.image;
      mopidy-push = mopidy.push-script;
    });
}