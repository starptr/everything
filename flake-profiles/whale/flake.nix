{
  description = "Safe container image push with runtime auth";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.systems.url = "github:nix-systems/default";

  outputs = inputs: (import ../outputs.nix) inputs;
}
