{ self, nixpkgs, ... } @ inputs: let
  pkgsFor = system: import nixpkgs { inherit system; };
  # Images always target the k8s nodes' arch, regardless of the host driving the build.
  imagePkgs = pkgsFor "x86_64-linux";

  # Patched autobrr: v1.80.0 (the version we run) + a one-line RSS fix. The pinned `nixpkgs`
  # above only has 1.64.0, so we pull autobrr from `nixpkgs-autobrr` (which ships 1.80.0) and
  # apply ONLY a source patch -- the Go vendorHash and pnpm frontend deps come from nixpkgs
  # unchanged, so there is no hash to chase. The patch makes the RSS enclosure-type check a
  # prefix match so nekoBT's "application/x-bittorrent;x-scheme-handler/magnet" enclosures are
  # accepted and the clean magnet is recovered (upstream uses exact `==` and drops them, which
  # is why Sonarr 404s on the base-URL-mangled magnet autobrr otherwise forwards). See
  # whale/patches/autobrr-rss-enclosure-type.patch and milky-way/lib/autobrr.libsonnet.
  autobrrPatched = (import inputs.nixpkgs-autobrr { system = "x86_64-linux"; }).autobrr.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/autobrr-rss-enclosure-type.patch ];
  });

  # andref-ipfs-depot: our Rust binary (Discord-gated IPFS uploader), built by its own crane flake
  # for x86_64-linux. The frontend assets are compiled into the binary (include_str!), so the image
  # needs nothing but the binary + its runtime closure + TLS roots + an init.
  andrefIpfsDepotBin = inputs.andref-ipfs-depot.packages.x86_64-linux.default;

  # yutobot-discord: our Node (discord.js) bot, built by its own buildNpmPackage flake for
  # x86_64-linux. The build wraps the app entrypoint into $out/bin/yutobot-discord on a pinned
  # Node 22; the assets (font + wii menu png) are inside the package and loaded via __dirname, so
  # the image needs only the app + its runtime closure (node, canvas's cairo/pango) + TLS roots +
  # tzdata + an init.
  yutobotDiscordApp = inputs.yutobot-discord.packages.x86_64-linux.default;

  # SeaDexArr (bbtufty) -- whale-built FORK of the pinned upstream `:main` image. NOT built from source
  # (it's a niche Python app not in nixpkgs): we pull the exact pinned digest -- which already carries the
  # qbittorrent-api 2025.11.1 login fix (see milky-way/lib/images.libsonnet) -- and patch ONE file in
  # place. Fix: add_torrent_to_qbit checks `result != "Ok."`, but qBittorrent 5.1+ returns a
  # TorrentsAddedMetadata dict from torrents/add (never "Ok."), so it false-raises "Failed to add torrent"
  # on every successful grab; the patch inspects failure_count instead. See
  # whale/patches/seadexarr-qbit5-add-response.patch and milky-way/lib/seadexarr.libsonnet. DROP THIS FORK
  # once upstream handles qBittorrent 5.x's add response. To bump the base, update imageDigest (+ re-hash).
  seadexarrUpstreamImage = imagePkgs.dockerTools.pullImage {
    imageName = "ghcr.io/bbtufty/seadexarr";
    imageDigest = "sha256:92d539222696bd312c372ee8c6915141025ea10c1daa1a5ebded2966236fdebf";
    finalImageName = "ghcr.io/bbtufty/seadexarr";
    finalImageTag = "main";
    os = "linux";
    arch = "amd64";
    # FOD hash of the pulled amd64 image tarball (from the first build's hash mismatch).
    sha256 = "sha256-YLR3i6JRqkesqc+9pieeN/d/M7suU3dKf3IOwYf7WKE=";
  };
  # Deterministic, VM-free patch (runAsRoot's runInLinuxVM and enableFakechroot's proot both proved
  # flaky on this builder): extract seadex_arr.py from the pulled image's layers with plain tar, apply
  # the patch, then layer just that one file over fromImage. `patch -p1` from the extracted rootfs
  # matches the patch's `a/app/...` paths.
  seadexarrPatchedModule = imagePkgs.runCommand "seadexarr-seadex_arr-patched.py" {
    nativeBuildInputs = [ imagePkgs.gnutar imagePkgs.jq imagePkgs.patch ];
  } ''
    mkdir extract && tar -xf ${seadexarrUpstreamImage} -C extract
    mkdir root
    for layer in $(jq -r '.[0].Layers[]' extract/manifest.json); do
      tar -xf "extract/$layer" -C root
    done
    ( cd root && patch -p1 < ${./patches/seadexarr-qbit5-add-response.patch} )
    cp root/app/seadexarr/modules/seadex_arr.py "$out"
  '';
  seadexarrPatchLayer = imagePkgs.runCommand "seadexarr-patch-layer" { } ''
    install -Dm644 ${seadexarrPatchedModule} "$out/app/seadexarr/modules/seadex_arr.py"
  '';
  # fromImage = the pinned upstream image; the overlay layer shadows just seadex_arr.py. buildLayeredImage
  # doesn't inherit fromImage's config, so restate the upstream runtime contract (Entrypoint/Env/WorkingDir,
  # read from the pulled image's config json) that lib/seadexarr.libsonnet depends on.
  seadexarrPatchedImage = imagePkgs.dockerTools.buildLayeredImage {
    name = "seadexarr";
    tag = "latest";
    fromImage = seadexarrUpstreamImage;
    contents = [ seadexarrPatchLayer ];
    config = {
      Entrypoint = [ "seadexarr" ];
      Cmd = [ "python3" ];
      Env = [
        "PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "CONFIG_DIR=/config"
      ];
      WorkingDir = "/app";
    };
  };

  # Creates an attrset with two system-keyed targets: the x86_64-linux image and a
  # per-host script to push it to the docker registry.
  # @param name: The name of the docker repository for the image.
  # @param buildLayeredImageArg: The arguments to pass to `dockerTools.buildLayeredImage`. The `name` property is optional, but can be specified here too.
  image-nix-artifacts = { name, buildLayeredImageArg ? null, image ? null }: let
      # Build a layered image from `buildLayeredImageArg`, OR accept a prebuilt `image` (e.g. a
      # `buildImage`/`fromImage` fork that patches an upstream image in place). The push-script,
      # digest-file, and system-keyed outputs are identical either way.
      builtImage = if image != null then image
                   else imagePkgs.dockerTools.buildLayeredImage ({
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

          # The digest is recorded cwd-relative, so run this from the everything repo root
          # (where exports/whale/digests/ lives). Fail fast rather than writing it elsewhere.
          digests_dir="exports/whale/digests"
          if [[ ! -d "$digests_dir" ]]; then
            echo "Error: '$digests_dir/' not found under $PWD." >&2
            echo "Run this from the root of an everything repo checkout." >&2
            exit 1
          fi

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
          digestfile="$PWD/$digests_dir/${name}.txt"
          skopeo --insecure-policy copy --digestfile "$digestfile" "docker-archive:${builtImage}" "$dest"
          echo "Done!"

          digest=$(cat "$digestfile")
          echo "Image manifest digest: $digest"
          echo "Digest written to $digestfile"
        '';
      };
    in {
      image = {
        x86_64-linux = builtImage;
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

  # autobrr (download automation) -- whale-built so we can ship the patched 1.80.0 binary
  # (autobrrPatched above). Mirrors the official image's runtime contract that
  # milky-way/lib/autobrr.libsonnet depends on: `autobrr --config /config` on :7474, with
  # HOME/XDG_* pointed at /config (autobrr writes config.toml + autobrr.db there; the iSCSI PVC
  # is mounted at /config and the AUTOBRR__* env + uid/gid 1000 are set by the libsonnet).
  # cacert is needed for HTTPS feed fetches; tzdata backs the TZ env; dumb-init is PID 1 so k8s
  # SIGTERM stops the pod promptly (same pattern as the other whale images).
  autobrr = image-nix-artifacts {
    name = "autobrr";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [
        autobrrPatched
        imagePkgs.cacert
        imagePkgs.tzdata
        imagePkgs.dumb-init
      ];
      config = {
        Entrypoint = [ "dumb-init" "--" "${autobrrPatched}/bin/autobrr" "--config" "/config" ];
        Env = [
          "HOME=/config"
          "XDG_CONFIG_HOME=/config"
          "XDG_DATA_HOME=/config"
          "SSL_CERT_FILE=${imagePkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          "ZONEINFO=${imagePkgs.tzdata}/share/zoneinfo"
        ];
        WorkingDir = "/app";
        ExposedPorts = { "7474/tcp" = {}; };
        Volumes = { "/config" = {}; };
      };
    };
  };

  # SeaDexArr fork -- see the seadexarrPatchedImage derivation comment above. Uses the prebuilt-`image`
  # path of image-nix-artifacts (buildImage/fromImage), not buildLayeredImageArg.
  seadexarr = image-nix-artifacts {
    name = "seadexarr";
    image = seadexarrPatchedImage;
  };

  # andref-ipfs-depot (Discord-gated IPFS uploader). Wraps the crane-built Rust binary above in a
  # minimal layered image: dumb-init is PID 1 so k8s SIGTERM stops the pod promptly; cacert +
  # SSL_CERT_FILE give the serenity bot's HTTPS calls to Discord a CA bundle. Listens on :8080
  # (matches lib/andref-ipfs-depot.libsonnet's containerPort + BIND_ADDR). See
  # milky-way/lib/andref-ipfs-depot.libsonnet.
  andref-ipfs-depot = image-nix-artifacts {
    name = "andref-ipfs-depot";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [
        andrefIpfsDepotBin
        imagePkgs.cacert
        imagePkgs.dumb-init
      ];
      config = {
        Entrypoint = [ "dumb-init" "--" "${andrefIpfsDepotBin}/bin/andref-ipfs-depot" ];
        Env = [
          "SSL_CERT_FILE=${imagePkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        ];
        ExposedPorts = { "8080/tcp" = {}; };
      };
    };
  };

  # Patched Shokofin (Jellyfin plugin) -- stable v6.0.5 + ONE upstream feature commit backported:
  # `VFS_UseSourceFileAsVersionIdentifier` (upstream 30eb9b55), which makes Jellyfin's multi-version
  # episode picker label each version by its source file's basename instead of the opaque
  # `[Shoko File=N]` VFS name. The option is gated (default off), so the build is behaviorally
  # identical to stock 6.0.5 until enabled. See
  # whale/patches/shokofin-source-file-version-identifier.patch and milky-way/lib/jellyfin.libsonnet.
  #
  # Only the BACKPORT is temporary. Once upstream ships this feature in a stable Shokofin, drop the
  # patch + buildDotnetModule + whale/shokofin-nuget-deps.json + the DLL overlay and collapse this to
  # a plain image that packages the stock release zip (fetchurl -> /plugin). The file-delivery image
  # itself, the images.libsonnet pin, and the jellyfin init container that consumes it are PERMANENT
  # -- they are how the plugin is installed declaratively, patched or not (never revert to a
  # hand-installed UI plugin).
  #
  # This is the repo's first buildDotnetModule. We build ONLY Shokofin.dll (the single patched
  # managed assembly) and OVERLAY it onto the pinned upstream release zip -- so every shipped
  # dependency DLL + meta.json comes from upstream unchanged and we never have to guess the dep set.
  # NuGet deps are vendored in whale/shokofin-nuget-deps.json (regenerate by pointing a scratch
  # buildDotnetModule flake at v6.0.5 + this patch and running `nix run .#default.fetch-deps`).
  shokofinSrc = imagePkgs.fetchFromGitHub {
    owner = "ShokoAnime";
    repo = "Shokofin";
    rev = "v6.0.5";
    hash = "sha256-vAbhbMnnfnFkBIramuRccuSvDb+WJKGG6hOX9V5luNc=";
  };
  shokofinPatchedBuild = imagePkgs.buildDotnetModule {
    pname = "shokofin";
    version = "6.0.5-sfvi";
    src = shokofinSrc;
    patches = [ ./patches/shokofin-source-file-version-identifier.patch ];
    # Collapse the multi-target (net9.0;net8) to a single net9.0 target: Jellyfin 10.11 is .NET 9, so
    # net8 is dead weight, and a single <TargetFramework> lets `dotnet publish` run without an
    # explicit -f (a plural <TargetFrameworks>, even with one value, forces multi-target publish).
    postPatch = ''
      substituteInPlace Shokofin/Shokofin.csproj \
        --replace-fail '<TargetFrameworks>net9.0;net8</TargetFrameworks>' '<TargetFramework>net9.0</TargetFramework>'
    '';
    projectFile = "Shokofin/Shokofin.csproj";
    nugetDeps = ./shokofin-nuget-deps.json;
    dotnet-sdk = imagePkgs.dotnetCorePackages.sdk_9_0;
    dotnet-runtime = imagePkgs.dotnetCorePackages.runtime_9_0;
    executables = [ ];   # a library plugin, no executables to wrap
    doCheck = false;
  };
  stockShokofinZip = imagePkgs.fetchurl {
    url = "https://github.com/ShokoAnime/Shokofin/releases/download/v6.0.5/shoko_6.0.5.0_for_10.11.zip";
    hash = "sha256-Pm/uMugqSAOExmr4jQhpvPaL7ZqJescCPzeur7Rma+8=";
  };
  # The installable plugin dir = the pinned upstream release zip with ONLY Shokofin.dll swapped for
  # our patched build, and autoUpdate disabled in meta.json so Jellyfin's updater can't replace the
  # patched DLL with a stock release.
  shokofinPluginDir = imagePkgs.runCommand "shokofin-plugin-6.0.5-sfvi" {
    nativeBuildInputs = [ imagePkgs.unzip imagePkgs.jq ];
  } ''
    mkdir -p "$out"
    unzip -q ${stockShokofinZip} -d "$out"
    cp -f ${shokofinPatchedBuild}/lib/shokofin/Shokofin.dll "$out/Shokofin.dll"
    jq '.autoUpdate = false' "$out/meta.json" > "$out/meta.json.tmp"
    mv "$out/meta.json.tmp" "$out/meta.json"
  '';
  # File-delivery image (the repo's first): bakes the plugin dir at /plugin plus busybox for the init
  # container's sh/cp. There is no service Entrypoint -- milky-way/lib/jellyfin.libsonnet runs this as
  # an init container that copies /plugin into Jellyfin's config PVC (cf. grand-central, which reuses
  # its own image as an init container).
  jellyfin-shokofin-plugin = image-nix-artifacts {
    name = "jellyfin-shokofin-plugin";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [ imagePkgs.busybox ];
      extraCommands = ''
        mkdir -p plugin
        cp -r ${shokofinPluginDir}/. plugin/
      '';
      config = {
        Cmd = [ "sh" ];
      };
    };
  };

  # yutobot-discord (Yuto's Discord bot). Wraps the buildNpmPackage app above in a minimal layered
  # image: dumb-init is PID 1 so k8s SIGTERM stops the pod promptly; cacert + SSL_CERT_FILE give
  # discord.js's HTTPS/gateway calls a CA bundle; tzdata + TZ back the welcome card's local-time
  # rendering (America/Los_Angeles, matching the app's original CapRover deploy). No server, so no
  # ExposedPorts. The app reads DISCORD_* from a .env in its CWD, so WorkingDir=/app (created empty
  # here) is where lib/yutobot-discord.libsonnet mounts the sops Secret. See
  # milky-way/lib/yutobot-discord.libsonnet.
  yutobot-discord = image-nix-artifacts {
    name = "yutobot-discord";
    buildLayeredImageArg = {
      tag = "latest";
      contents = [
        yutobotDiscordApp
        imagePkgs.cacert
        imagePkgs.tzdata
        imagePkgs.dumb-init
      ];
      # WorkingDir target for the mounted .env; layered images don't create it implicitly.
      extraCommands = ''
        mkdir -p app
      '';
      config = {
        Entrypoint = [ "dumb-init" "--" "${yutobotDiscordApp}/bin/yutobot-discord" ];
        Env = [
          "SSL_CERT_FILE=${imagePkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          "TZ=America/Los_Angeles"
          "ZONEINFO=${imagePkgs.tzdata}/share/zoneinfo"
        ];
        WorkingDir = "/app";
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
      autobrr-image = autobrr.image.x86_64-linux;
      autobrr-push = autobrr.push-script.x86_64-linux;
      seadexarr-image = seadexarr.image.x86_64-linux;
      seadexarr-push = seadexarr.push-script.x86_64-linux;
      andref-ipfs-depot-image = andref-ipfs-depot.image.x86_64-linux;
      andref-ipfs-depot-push = andref-ipfs-depot.push-script.x86_64-linux;
      jellyfin-shokofin-plugin-image = jellyfin-shokofin-plugin.image.x86_64-linux;
      jellyfin-shokofin-plugin-push = jellyfin-shokofin-plugin.push-script.x86_64-linux;
      yutobot-discord-image = yutobot-discord.image.x86_64-linux;
      yutobot-discord-push = yutobot-discord.push-script.x86_64-linux;
    };
    aarch64-darwin = {
      whale-push-example = example-artifacts.push-script.aarch64-darwin;
      mopidy-push = mopidy.push-script.aarch64-darwin;
      grand-central-push = grand-central.push-script.aarch64-darwin;
      autobrr-push = autobrr.push-script.aarch64-darwin;
      seadexarr-push = seadexarr.push-script.aarch64-darwin;
      andref-ipfs-depot-push = andref-ipfs-depot.push-script.aarch64-darwin;
      jellyfin-shokofin-plugin-push = jellyfin-shokofin-plugin.push-script.aarch64-darwin;
      yutobot-discord-push = yutobot-discord.push-script.aarch64-darwin;
    };
  };

  devShells = {
    x86_64-linux.default = mkAuthShell (pkgsFor "x86_64-linux");
    aarch64-darwin.default = mkAuthShell (pkgsFor "aarch64-darwin");
  };
}
