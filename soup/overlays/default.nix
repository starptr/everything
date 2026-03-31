{ maybe-flake-inputs }: {
  # Add your overlays here
  #
  # my-overlay = import ./my-overlay;
  expand-love = final: super: {
    love = if final.stdenv.hostPlatform.isDarwin
      then (final.callPackage ./.. { inherit maybe-flake-inputs; }).love
      else super.love;
  };

  # This overlay naively adds all of the pkgs.
  #default = (
  #  # You can use this as a nixpkgs overlay. This is useful in the
  #  # case where you don't want to add the whole NUR namespace to your
  #  # configuration.
  #  # It will add all of the pkgs in the root default.nix.
  #  
  #  self: super:
  #  let
  #    isReserved = n: n == "lib" || n == "overlays" || n == "modules";
  #    nameValuePair = n: v: { name = n; value = v; };
  #    nurAttrs = import ./../default.nix { pkgs = super; };
  #  
  #  in
  #  builtins.listToAttrs
  #    (map (n: nameValuePair n nurAttrs.${n})
  #      (builtins.filter (n: !isReserved n)
  #        (builtins.attrNames nurAttrs)))
  #);
  chaseln = if builtins.isNull maybe-flake-inputs
    then
      final: super: {
        chaseln = (final.callPackage ../. { inherit maybe-flake-inputs; }).chaseln;
      }
    else
      maybe-flake-inputs.chaseln.overlays.default;
  
  check-gits = if builtins.isNull maybe-flake-inputs
    then
      final: super: {
        check-gits = (final.callPackage ../. { inherit maybe-flake-inputs; }).check-gits;
      }
    else
      maybe-flake-inputs.check-gits.overlays.default;

  jujutsu = if builtins.isNull maybe-flake-inputs
    then
      final: super: {
        jujutsu = (final.callPackage ../. { inherit maybe-flake-inputs; }).jujutsu;
      }
    else
      maybe-flake-inputs.jujutsu.overlays.default;
  
  claude-code-overlay = if builtins.isNull maybe-flake-inputs
    then
      throw "claude-code-overlay overlay requires flake inputs"
    else
      maybe-flake-inputs.claude-code-overlay.overlays.default;
}
