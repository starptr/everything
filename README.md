# Everything

This monorepo contains many things, including
- Tilderef setup,
- The Milky-Way k3s cluster manifests,
- Pulumi infrastructure declarations,
- NixOS modules,

and more. Some advantages of using a monorepo is that
- Dependencies between these projects are easier to manage and update (eg. a single source of truth is easily depended on by everything else),
- Build systems can be re-used instead of duplicated for each git repository,
etc.

## Overview

- `eight/` defines domain records using octodns.
    - For example, the `andref.app` domain records are defined here.
    - This is a single source of truth for all domains.
- `experimental/` contains new projects that may or may not be abandoned.
    - This is a safe space to play with ideas quickly as-needed.
- `exports/` contains "built" artifacts which 1. are not nix-hermetic, or 2. is depended on by code which cannot evaluate Nix IFD.
    - For example, `jupiter/` is not nix-hermetic (because it uses Pulumi which is not hermetic), so its output is written to `exports/jupiter/generated.json` as a single source of truth.
    - If `eight/` was written in Jsonnet, it would not be able to evaluate Nix IFD, so `jupiter/` would still need to write to `exports/jupiter/`, even if `jupiter/` was nix-hermetic.
- `flake-profiles/` contains all Nix flakes.
    - Every NixOS/Darwin/Home-Manager configuration should have its own dedicated flake, because each configuration should have its own lockfile. Otherwise, updating machine-1 might unexpectedly break the configuration of machine-2.
    - `flake-profiles/everything-devenv/` contains targets which are ok with rolling updates. This flake is updated frequently, and projects which are unlikely to fail from a new version of a dependency can use this flake.
- `jupiter/` declares its infrastructure using Pulumi.
    - The main Python file uses Pulumi to create Cloud resources, and also writes relevant data to `exports/jupiter/generated.json`.
- `lib/` contains utility Nix functions.
- `magic/` defines magic values (or "anonymous" values), and serves as a single source of truth.
    - For example, the absolute path of this repository that's checked out in machine-1 is a magic value.
- `milky-way/` defines the k3s cluster manifest.
- `secrets/` contains sensitive values encrypted with sops-nix.
- `tilderef/` contains miscellaneous files relevant to declaring the tilderef configuration.
- `venus/` contains all NixOS/Darwin/Home-Manager modules and configurations, as well as config files for apps.
- `whale/` specifies targets for building container images and scripts for pushing them to registries.