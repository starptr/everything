# native runner — wraps a prebuilt store binary (model: soup/pkgs/jujutsu-bin).
# runnerConfig = { bin :: derivation; exe ? "${bin}/bin/${bin.meta.mainProgram}"; }
{
  pkgs,
  lib,
  hcLib,
}:
spec:
let
  cfg = spec.runnerConfig;
  bin = cfg.bin;
  exe = cfg.exe or "${bin}/bin/${lib.getName bin}";
in
{
  package = bin;
  runtimeInputs = [ bin ];
  reconcile = "";
  launchCmd = lib.escapeShellArg exe;
}
