# MECCHA CHAMELEON — the Part 2 validation target (DESIGN §9.2): a Windows-only Steam
# game (App ID 4704690). Tier B / Pattern B: the ENVIRONMENT (pinned wine + builtin DXMT
# + winetricks) is declarative here; the game BYTES are your own copy, captured per-user
# into the store (never fetched, never cached).
#
# It ships UNCAPTURED (versions = {}, play = null): `nix run .#meccha-chameleon` prints
# the capture steps. After `hc-steam-provision` + `hc-capture`, set `play` + paste the
# `versions."<v>"` stanza below, and confirm `gameFolder`/`exe` against the real install
# (the values here are best-guesses until first capture). If MECCHA turns out to enforce
# Steam DRM at launch, set runnerConfig.launchViaSteam = true (non-hermetic fallback).
{
  pkgs,
  lib,
  hcLib,
}:
{
  runner = "wine";
  gameName = "meccha-chameleon";
  displayName = "MECCHA CHAMELEON";
  drm = "steamStub";

  play = "24149874"; # set to the captured version string once hc-capture prints it
  versions = {
    # versions."1.0.0" = { sha256 = "…"; buildid = "…"; };   # ← from hc-capture
    # Manually copied from `versions."24149874" = { sha256 = "06c6vsl0wrqv8inis7r1gzr4ycbbr9hjdd4xcvn9ck9l7xnqd758"; buildid = "24149874"; };`:
    "24149874" = { sha256 = "06c6vsl0wrqv8inis7r1gzr4ycbbr9hjdd4xcvn9ck9l7xnqd758"; buildid = "24149874"; };
  };

  runnerConfig = {
    wine = import ../lib/wine-pin.nix; # pinned frankea/Whisky bundle (shared default)
    graphics = "dxmt"; # wine's builtin DXMT, forced builtin
    winetricks = [ "vcrun2022" ];
    steamAppId = 4704690;
    gameFolder = "MECCHA CHAMELEON"; # steamapps/common/<folder> (= .acf installdir), confirmed
    exe = "PenguinHotel.exe"; # relative to gameFolder, confirmed from the install
    # launchViaSteam = true;           # uncomment only if it enforces Steam DRM at launch
  };
}
