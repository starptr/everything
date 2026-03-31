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
  #default = import ../overlay.nix;
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
