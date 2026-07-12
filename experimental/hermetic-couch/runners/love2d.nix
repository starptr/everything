# love2d runner — runs a LÖVE game (a directory or .love containing main.lua).
# runnerConfig = { love :: derivation; gameSrc :: path/derivation; }
# LÖVE manages its own save dir (~/Library/Application Support/LOVE/<identity>), so no
# reconcile is needed for this runner.
{
  pkgs,
  lib,
  hcLib,
}:
spec:
let
  cfg = spec.runnerConfig;
in
{
  package = cfg.gameSrc;
  runtimeInputs = [ cfg.love ];
  reconcile = "";
  launchCmd = "love ${cfg.gameSrc}";
}
