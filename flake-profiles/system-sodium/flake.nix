{
  description = "Yuto's system profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-firefox-darwin = {
      url = "github:bandithedoge/nixpkgs-firefox-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    herdr = {
      url = "github:ogulcancelik/herdr/v0.7.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    jellyfin-mpv-shim-darwin = {
      url = "path:./../../experimental/jellyfin-mpv-shim-darwin-compat";
      ##inputs.nixpkgs.follows = "nixpkgs"; # TODO: migrate to support new shim
    };

    systems.url = "github:nix-systems/default"; # For soup
    soup = {
      url = "path:./../../soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs"; # Does not need to be devenv's nixpkgs, since we don't use soup's devshell
        systems.follows = "systems";
        devenv.follows = "devenv";
      };
    };
    # TODO: remove these by removing them from soup
    # TODO: move soup into this monorepo
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
    ];
  };

  outputs = inputs @ { self, nixpkgs, ... }: let
    system = "aarch64-darwin";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Recover the linux-builder VM from nix-store corruption (symptom: x86_64-linux
    # builds fail with `path '…' is not valid` because the guest's binfmt config got
    # truncated, so QEMU x86_64 emulation never registers). Resets the persistent
    # qcow2 disk (keys/ are preserved) so the build closure re-copies cleanly.
    #   nix run ./flake-profiles/system-sodium#reset-linux-builder
    packages.${system}.reset-linux-builder = pkgs.writeShellApplication {
      name = "reset-linux-builder";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        set -euo pipefail

        echo "Resetting the linux-builder VM (you will be prompted for sudo)."
        echo "This wipes the builder's persistent nix store (keys/ are preserved) and"
        echo "forces a clean re-copy of the build closure on next build. Use it to"
        echo "recover from 'path ... is not valid' x86_64-linux build failures."
        echo

        sudo launchctl bootout system/org.nixos.linux-builder || echo "(service was not running)"
        sleep 2
        sudo rm -f /var/lib/linux-builder/nixos.qcow2
        sudo launchctl bootstrap system /Library/LaunchDaemons/org.nixos.linux-builder.plist

        echo "Waiting for the builder to come back up..."
        for _ in $(seq 1 40); do
          if sudo ssh -i /etc/nix/builder_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=3 builder@linux-builder true 2>/dev/null; then
            break
          fi
          sleep 3
        done

        echo "Verifying x86_64 emulation is registered..."
        if sudo ssh -i /etc/nix/builder_ed25519 -o StrictHostKeyChecking=no builder@linux-builder "test -e /proc/sys/fs/binfmt_misc/x86_64-linux"; then
          echo "OK: x86_64-linux binfmt handler is registered. The builder is ready."
        else
          echo "WARNING: x86_64-linux binfmt handler not found. Inspect the builder:"
          echo "  sudo ssh -i /etc/nix/builder_ed25519 builder@linux-builder"
          exit 1
        fi
      '';
    };

    darwinConfigurations."Yutos-Sodium" = inputs.nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ./../../venus/modules/nixos-darwin/sodium.nix
        inputs.home-manager.darwinModules.home-manager
        {
          nixpkgs = {
            overlays = [
              (self: super: {
                jellyfin-mpv-shim = inputs.jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
              })
              (final: super: {
                herdr = inputs.herdr.packages."aarch64-darwin".default;
              })
              #chaseln.overlays.chaseln
              inputs.soup.overlays.chaseln
              #inputs.soup.overlays.jujutsu
              (final: super: {
                jujutsu = inputs.soup.legacyPackages."aarch64-darwin".jujutsu-bin;
              })
              inputs.soup.overlays.claude-code-overlay
              (final: super: {
                check-gits = inputs.soup.legacyPackages."aarch64-darwin".check-gits;
              })
              (final: super: {
                lute3 = inputs.soup.legacyPackages."aarch64-darwin".lute3;
              })
            ];
            config = import ./../../venus/app-configs/nixpkgs-config.nix; # Configures pkgs for evaluating this darwinConfiguration ("buildtime" config)
          };
        }
        {
          home-manager.useGlobalPkgs = true;
          #home-manager.useUserPackages = true; # This breaks fish??
          home-manager.users.yuto = {
            imports = [
              inputs.sops-nix.homeManagerModules.sops
              (import ./../../venus/modules/home-manager/sodium.nix)
            ];
          };
          home-manager.extraSpecialArgs = {
            inherit (inputs) nixpkgs;
          };
        }
      ];
    };
  };
}
