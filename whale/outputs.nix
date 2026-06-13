{ self, nixpkgs, ... } @ inputs: let
  magic = import ./../magic/common/constants.nix inputs.nixpkgs;
  machine = "sodium"; # Current machine name
  digests-directory-home-relative-pathstr = magic.relativePathStrings.${machine}.whale-digests;

  pkgsFor = system: import nixpkgs { inherit system; };
  # Images always target the k8s nodes' arch, regardless of the host driving the build.
  imagePkgs = pkgsFor "x86_64-linux";

  # Creates an attrset with two system-keyed targets: the x86_64-linux image and a
  # per-host script to push it to the docker registry.
  # @param name: The name of the docker repository for the image.
  # @param buildLayeredImageArg: The arguments to pass to `dockerTools.buildLayeredImage`. The `name` property is optional, but can be specified here too.
  image-nix-artifacts = { name, buildLayeredImageArg }: let
      image = imagePkgs.dockerTools.buildLayeredImage ({
        inherit name;
      } // buildLayeredImageArg);
      # The push-script is built from the host's pkgs so it runs natively (native
      # skopeo, native ~/.config/containers/auth.json), while still pushing the
      # x86_64-linux image (the docker-archive tarball is arch-agnostic).
      mkPushScript = pkgs: pkgs.writeShellApplication {
        name = "push-${name}";
        # We have to use skopeo; docker CLI requires the docker daemon to be running.
        runtimeInputs = [ pkgs.skopeo pkgs.jq pkgs.docker-credential-helpers ];
        text = ''
          set -euo pipefail

          dest="docker://docker.io/yuto7/${name}:latest"

          echo "Checking credentials..."
          # XDG_RUNTIME_DIR is unset on macOS; default to empty so `set -u` doesn't abort.
          if [[ -f "''${XDG_RUNTIME_DIR:-}/containers/auth.json" ]]; then
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
      image = {
        x86_64-linux = image;
      };
      push-script = {
        x86_64-linux = mkPushScript (pkgsFor "x86_64-linux");
        aarch64-darwin = mkPushScript (pkgsFor "aarch64-darwin");
      };
    };

  example-artifacts = image-nix-artifacts {
    name = "example-image";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [ imagePkgs.curl ];
      config.Cmd = [ "curl" "--version" ];
    };
  };
  mopidy = image-nix-artifacts {
    name = "mopidy";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [
        imagePkgs.curl
        imagePkgs.dumb-init
        imagePkgs.gnupg

        imagePkgs.mopidy
        imagePkgs.mopidy-local
        imagePkgs.mopidy-mpd
        imagePkgs.mopidy-spotify
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

  # `nix develop` target for a long-lived `skopeo login`. Uses the same skopeo (and
  # nixpkgs) as the push-scripts, so the auth.json written here is always compatible.
  mkAuthShell = pkgs: pkgs.mkShell {
    packages = [ pkgs.skopeo pkgs.jq pkgs.docker-credential-helpers ];
    shellHook = ''
      echo "whale auth shell — run once for long-lived creds:  skopeo login docker.io"
      echo "creds persist in ~/.config/containers/auth.json and are reused by whale-push-*."
    '';
  };
in {
  packages = {
    x86_64-linux = {
      whale-example-image = example-artifacts.image.x86_64-linux;
      whale-push-example = example-artifacts.push-script.x86_64-linux;
      mopidy-image = mopidy.image.x86_64-linux;
      mopidy-push = mopidy.push-script.x86_64-linux;
    };
    aarch64-darwin = {
      whale-push-example = example-artifacts.push-script.aarch64-darwin;
      mopidy-push = mopidy.push-script.aarch64-darwin;
    };
  };

  devShells = {
    x86_64-linux.default = mkAuthShell (pkgsFor "x86_64-linux");
    aarch64-darwin.default = mkAuthShell (pkgsFor "aarch64-darwin");
  };
}
