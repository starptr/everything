{
  description = "papyrus — a canvas GUI frontend for silverwood workstreams (vendored from Fallomai/openui)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # Bun-native packaging. Consumes the project's real bun.lock (via committed
    # bun.nix) and keeps a real node_modules, so bun-pty's FFI .dylib still
    # dlopens at runtime — a `bun build --compile` single binary breaks it
    # (Bun #30717). See VENDOR.md. (bun2nix is a small Rust tool built from
    # source unless its nix-community cachix cache is a trusted substituter.)
    bun2nix.url = "github:nix-community/bun2nix?ref=2.1.1";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs";

    # silverwood — the backend papyrus shells out to at runtime. A RELATIVE path
    # input (Nix 2.26+): because papyrus's flake is inside the monorepo git repo,
    # Nix resolves `../silverwood` within that same git tree, so it respects
    # .gitignore (excludes silverwood's ~1.5G target/) with no absolute path and no
    # extra copy. NOT `git+file:../..` — a relative git+file URL misparses `file`
    # as an ssh host. Unlike soup (mirrored to github, so it must use an absolute
    # path), papyrus is only ever built in-tree. silverwood keeps its own nixpkgs.
    silverwood.url = "path:../silverwood";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      bun2nix,
      silverwood,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib stdenv;

        # bun2nix's builders (writeBunApplication / mkDerivation / fetchBunDeps /
        # hook) are exposed as passthru on its default package.
        b2n = bun2nix.packages.${system}.default;

        # The silverwood CLI (wrapped with jj + git on PATH). papyrus's server
        # shells out to it for all durable state.
        silverwood-bin = silverwood.packages.${system}.default;

        # The terminal fonts the client self-hosts, assembled from nixpkgs so they're
        # reproducible (no CDN) and each ships real Regular/Bold/Italic/BoldItalic faces.
        # Single source of truth for both the client build (preBuild below) and the dev
        # sync script (scripts/sync-terminal-fonts.sh); `nix build .#terminalFonts`.
        terminalFonts = pkgs.runCommandLocal "papyrus-terminal-fonts" { } ''
          mkdir -p $out
          cp ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-{Regular,Bold,Italic,BoldItalic}.ttf $out/
          cp ${pkgs.nerd-fonts.iosevka}/share/fonts/truetype/NerdFonts/Iosevka/IosevkaNerdFont{,Mono}-{Regular,Bold,Italic,BoldItalic}.ttf $out/
          cp ${pkgs.nerd-fonts.iosevka-term}/share/fonts/truetype/NerdFonts/IosevkaTerm/IosevkaTermNerdFont{,Mono}-{Regular,Bold,Italic,BoldItalic}.ttf $out/
        '';

        # The Vite/React client, built to static `dist`. Pure JS (no native
        # modules); installed + built with bun from client/bun.nix.
        client = b2n.mkDerivation {
          pname = "papyrus-client";
          version = "1.2.1";
          src = ./client;
          bunDeps = b2n.fetchBunDeps { bunNix = ./client/bun.nix; };
          # Drop the self-hosted fonts into Vite's publicDir first (inline, not a preBuild hook —
          # the custom buildPhase string below would skip runHook preBuild), so Vite copies them
          # verbatim into dist/fonts/ and they're served at /fonts/*.ttf (see index.css).
          buildPhase = ''
            mkdir -p public/fonts
            cp ${terminalFonts}/*.ttf public/fonts/
            bun run build
          ''; # package.json build: tsc && vite build -> dist
          installPhase = ''
            runHook preInstall
            cp -r dist "$out"
            runHook postInstall
          '';
        };

        # `bun test` (happy-dom + Testing Library) — unit + behavioral tests. Runs
        # in the bun-only sandbox; a red test fails `nix flake check`. See TESTING.md.
        client-tests = b2n.mkDerivation {
          pname = "papyrus-client-tests";
          version = "1.2.1";
          src = ./client;
          bunDeps = b2n.fetchBunDeps { bunNix = ./client/bun.nix; };
          buildPhase = "bun test";
          installPhase = "touch $out";
        };

        # The Bun server, packaged as a runnable app that keeps its real
        # node_modules (bun-pty's native .dylib must dlopen at runtime). There is
        # no bundle/compile step — Bun executes the TypeScript directly.
        papyrus = b2n.writeBunApplication {
          packageJson = ./package.json; # -> pname "papyrus" + version
          src = ./.;
          bunDeps = b2n.fetchBunDeps { bunNix = ./bun.nix; };

          # No `bun build`: run server/index.ts as-is. Also makes dontFixup
          # default true (no buildPhase), so the .dylib is never stripped.
          dontUseBunBuild = true;

          # Keep bun-pty's per-platform prebuilt binary; darwin wants symlinks.
          bunInstallFlags = [
            "--cpu=*"
          ]
          ++ lib.optionals (stdenv.hostPlatform.system != "x86_64-linux") [
            "--linker=isolated"
            "--backend=symlink"
          ];

          startScript = "bun run server/index.ts";

          # writeBunApplication's wrapper --chdir's into $out/share/papyrus at
          # runtime, so server/index.ts's `serveStatic({ root: "./client/dist" })`
          # resolves there — place the built client accordingly. Then re-wrap to
          # (1) put `silverwood` on PATH — the server shells out to it for all
          # durable state (it carries its own jj + git) — and (2) capture the
          # user's launch dir into LAUNCH_CWD *before* that chdir (used for display
          # + as the default cwd). papyrus itself writes nothing to disk.
          postInstall = ''
            cp -r ${client} "$out/share/papyrus/client/dist"

            mv "$out/bin/papyrus" "$out/bin/.papyrus-inner"
            makeWrapper "$out/bin/.papyrus-inner" "$out/bin/papyrus" \
              --prefix PATH : ${silverwood-bin}/bin \
              --run 'export LAUNCH_CWD="''${LAUNCH_CWD:-$PWD}"'
          '';
        };
      in
      {
        packages = {
          default = papyrus;
          inherit client terminalFonts;
        };

        checks = {
          inherit client client-tests;
          papyrus = papyrus;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = papyrus;
        }
        // {
          meta.description = "Run the papyrus server (serves the bundled canvas UI on :6968).";
        };

        devShells.default = pkgs.mkShell {
          # bun for dev (`bun install && bun run dev`); bun2nix regenerates bun.nix.
          packages = [
            pkgs.bun
            b2n
          ];
        };
      }
    );
}
