{
  description = "Safe container image push with runtime auth";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  # Separate nixpkgs that ships autobrr 1.80.0 (the version we run); the pinned `nixpkgs`
  # above still has 1.64.0. Isolated as its own input so bumping it to rebuild the patched
  # autobrr image doesn't churn the other whale images (mopidy/grand-central).
  inputs.nixpkgs-autobrr.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  # The andref-ipfs-depot crate (crane flake). whale consumes its built x86_64-linux binary and
  # wraps it in a minimal image. Self-contained (its own pinned nixpkgs), so it doesn't follow
  # whale's nixpkgs.
  inputs.andref-ipfs-depot.url = "path:./../../andref-ipfs-depot";
  # The yutobot-discord Node app (buildNpmPackage flake). whale consumes its built x86_64-linux
  # package and wraps it in a minimal image. Self-contained (its own pinned nixpkgs / Node 22), so
  # it doesn't follow whale's nixpkgs.
  inputs.yutobot-discord.url = "path:./../../yutobot-discord";
  inputs.systems.url = "github:nix-systems/default";

  outputs = inputs: (import ./../../whale/outputs.nix) inputs;
}
