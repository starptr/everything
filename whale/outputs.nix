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
        runtimeInputs = [ pkgs.skopeo pkgs.docker-credential-helpers ];
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
          # --digestfile records the MANIFEST digest of the image as pushed to the
          # registry (what you pull with image@sha256:...). This is the value
          # docker.io lists; do NOT use `inspect --raw | .config.digest` (that is the
          # config-blob digest, which is not a pullable manifest reference).
          digestfile="$HOME/${digests-directory-home-relative-pathstr}/${name}.txt"
          skopeo --insecure-policy copy --digestfile "$digestfile" "docker-archive:${image}" "$dest"
          echo "Done!"

          digest=$(cat "$digestfile")
          echo "Image manifest digest: $digest"
          echo "Digest written to $digestfile"
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
      contents = [ imagePkgs.curl imagePkgs.coreutils imagePkgs.dumb-init ];
      config = {
        # dumb-init is PID 1 and forwards signals (so k8s SIGTERM terminates the pod
        # promptly); sleep keeps the container alive as a long-running test target.
        # curl stays available for `kubectl exec ... -- curl --version`.
        Entrypoint = [ "dumb-init" "--" ];
        Cmd = [ "sleep" "infinity" ];
      };
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

  # Minimal sshd "binary carrier" for the grand-central jump bastion. Bakes in NO policy:
  # sshd_config and authorized_keys are mounted at runtime from ConfigMaps and the host-key
  # identity from an iSCSI PVC (see milky-way/lib/grand-central.libsonnet), so the only thing
  # this image provides is the openssh binaries + the two users/dirs sshd needs to start.
  #   * `sshd` (uid 74) is openssh's compiled-in privilege-separation user; it AND the privsep
  #     dir /var/empty (root-owned, 0755) must exist or sshd aborts at startup.
  #   * `relay` is the single login user every client/target authenticates as; nologin shell
  #     because it only ever does `-N` port forwarding (no shell is spawned for -R/-W).
  # busybox supplies /bin/sh for the init container's host-key seeding loop (which also needs
  # ssh-keygen from openssh -- same image is reused as the init image, mirroring sftp).
  grand-central = image-nix-artifacts {
    name = "grand-central";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [
        imagePkgs.openssh
        imagePkgs.busybox
        imagePkgs.dumb-init
      ];
      extraCommands = ''
        mkdir -p etc home/relay/.ssh var/empty var/log etc/grand-central
        printf '%s\n' \
          'root:x:0:0:root:/root:/bin/sh' \
          'sshd:x:74:74:sshd privsep:/var/empty:/sbin/nologin' \
          'relay:x:1000:1000:relay:/home/relay:/sbin/nologin' \
          > etc/passwd
        printf '%s\n' \
          'root:x:0:' \
          'sshd:x:74:' \
          'relay:x:1000:' \
          'nogroup:x:65534:' \
          > etc/group
        chmod 0755 var/empty
        chmod 0700 home/relay/.ssh
      '';
      config = {
        # dumb-init reaps zombies and forwards SIGTERM so k8s can stop the pod promptly.
        # sshd -D foreground, -e log to stderr (-> pod logs), -f the mounted declarative config.
        Entrypoint = [ "dumb-init" "--" ];
        Cmd = [ "${imagePkgs.openssh}/bin/sshd" "-D" "-e" "-f" "/etc/grand-central/sshd_config" ];
        ExposedPorts = { "22/tcp" = {}; };
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
      grand-central-image = grand-central.image.x86_64-linux;
      grand-central-push = grand-central.push-script.x86_64-linux;
    };
    aarch64-darwin = {
      whale-push-example = example-artifacts.push-script.aarch64-darwin;
      mopidy-push = mopidy.push-script.aarch64-darwin;
      grand-central-push = grand-central.push-script.aarch64-darwin;
    };
  };

  devShells = {
    x86_64-linux.default = mkAuthShell (pkgsFor "x86_64-linux");
    aarch64-darwin.default = mkAuthShell (pkgsFor "aarch64-darwin");
  };
}
