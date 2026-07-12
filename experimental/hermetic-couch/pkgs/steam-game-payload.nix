# A captured Steam game as a content-addressed store DIRECTORY (DESIGN §4 Pattern B, §1
# Tier A). The bytes are the user's OWN install — unfree, per-user, sometimes CEG
# machine-bound — so they are NOT fetched by URL. `hc-capture` adds the game dir straight
# into the local store via `nix-store --add-fixed --recursive`; `requireFile` (recursive)
# then resolves that exact store path by its per-user NAR hash, or fails the build with
# capture instructions if it's absent. No tar and no unpack — the store path is the game
# directory itself. Marked unfree so it's never pushed to a shared cache.
{
  lib,
  requireFile,
}:
{
  name,
  version,
  sha256,
}:
(requireFile {
  name = "${name}-${version}";
  inherit sha256;
  hashMode = "recursive";
  message = ''
    hermetic-couch: no captured payload for ${name} ${version}.
    These bits are your own (unfree) copy — provision + capture them first:
      nix run .#hc-steam-provision      # boot Steam, log in, install the game
      nix run .#hc-capture -- ${name}   # version defaults to the Steam buildid
    then set `play = "${version}"` and paste the printed `versions."${version}"`
    stanza into games/${name}.nix, and build with NIXPKGS_ALLOW_UNFREE=1.
  '';
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      description = "Captured Steam game payload for ${name} ${version} (per-user, content-addressed)";
      license = lib.licenses.unfree;
      platforms = lib.platforms.darwin;
      # Lets the flake's allowUnfreePredicate permit exactly hermetic-couch's own captures.
      hermeticCouchCaptured = true;
    };
  })
