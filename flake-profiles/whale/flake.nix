{
  description = "Safe container image push with runtime auth";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  # Separate nixpkgs that ships autobrr 1.80.0 (the version we run); the pinned `nixpkgs`
  # above still has 1.64.0. Isolated as its own input so bumping it to rebuild the patched
  # autobrr image doesn't churn the other whale images (mopidy/grand-central).
  inputs.nixpkgs-autobrr.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";

  outputs = inputs: (import ./../../whale/outputs.nix) inputs;
}
