# Compose a game spec + a runner adapter into a launcher (writeShellScriptBin) and a
# store .app bundle. The launcher exports $INSTANCE_DIR (the game's mutable state dir,
# created at launch), runs the runner's idempotent `reconcile`, then execs `launchCmd`.
# `runners` is passed in at call time to avoid a lib<->runners import cycle.
{
  pkgs,
  lib,
  hcLib,
}:
{
  name,
  spec,
  runners,
}:
let
  runner = runners.${spec.runner} spec;

  instanceRel = spec.instanceRel or "hermetic-couch/${name}";
  displayName = spec.displayName or name;
  icon = spec.icon or null;
  args = lib.attrByPath [ "launch" "args" ] [ ] spec;
  env = lib.attrByPath [ "launch" "env" ] { } spec;
  runtimeInputs = runner.runtimeInputs or [ ];

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}") env
  );

  launcher = pkgs.writeShellScriptBin name ''
    set -euo pipefail
    export PATH=${lib.escapeShellArg (lib.makeBinPath runtimeInputs)}''${PATH:+:$PATH}
    INSTANCE_DIR="$HOME/Library/Application Support/${instanceRel}"
    mkdir -p "$INSTANCE_DIR"
    ${envExports}
    ${runner.reconcile or ""}
    exec ${runner.launchCmd} ${lib.escapeShellArgs args} "$@"
  '';

  app = hcLib.mkAppBundle {
    inherit name displayName icon;
    exec = "${launcher}/bin/${name}";
  };
in
{
  inherit launcher app;
  package = runner.package;
}
