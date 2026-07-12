# hc-capture — the NON-hermetic capture step (DESIGN §9.2 step 3, §4 Pattern B). Adds a
# game the user installed via hc-steam-provision to the LOCAL store as a content-addressed
# DIRECTORY (recursive fixed-output), and prints the per-user `versions."<v>"` stanza.
# No tarball / no re-expansion — the store path IS the game dir (one copy). NAR hashing is
# canonical, so re-capturing the same install is stable.
#
# GAME-AWARE + minimal args: `games` is a slug→{ appId; folder; } table baked from the
# wine game specs at build time, and the version defaults to Steam's authoritative
# buildid (read from the .acf). So the common case is just `hc-capture <slug>` — the
# appid, install folder, and version are all derived. Positional [version] [appid]
# [folder] override, for a custom label or an ad-hoc game not declared in a spec.
#
# The bytes never leave the machine and are never fetched — the stanza is unique per user
# (unfree, sometimes CEG machine-bound).
{
  writeShellApplication,
  lib,
  coreutils,
  gnugrep,
  nix,
  games ? { },
}:
let
  known = lib.attrNames games;
  knownStr = if known == [ ] then "(none)" else lib.concatStringsSep ", " known;
  # One case arm per declared Steam game → its static appid + folder.
  caseArms = lib.concatStrings (
    lib.mapAttrsToList (slug: g: ''
      ${lib.escapeShellArg slug}) def_appid=${toString g.appId}; def_folder=${lib.escapeShellArg g.folder} ;;
    '') (lib.filterAttrs (_: g: g.appId != null) games)
  );
in
writeShellApplication {
  name = "hc-capture";
  runtimeInputs = [
    coreutils
    gnugrep
    nix
  ];
  text = ''
    slug="''${1:-}"
    if [ -z "$slug" ]; then
      echo "usage: hc-capture <game> [version] [appid] [steam-folder]" >&2
      echo "  known games: ${knownStr}" >&2
      echo "  version defaults to the Steam buildid; appid + folder default from the spec." >&2
      exit 2
    fi
    version_arg="''${2:-}"

    # Resolve appid + folder from the framework's per-game table (slug lookup).
    def_appid=""
    def_folder=""
    case "$slug" in
      ${caseArms}
      *) : ;;
    esac
    appid="''${3:-$def_appid}"
    folder="''${4:-$def_folder}"
    if [ -z "$appid" ] || [ -z "$folder" ]; then
      echo "hc-capture: '$slug' is not a known Steam game in hermetic-couch." >&2
      echo "  known games: ${knownStr}" >&2
      echo "  for an ad-hoc game: hc-capture <slug> <version> <appid> <steam-folder>" >&2
      exit 2
    fi

    root="''${HC_PROVISION_DIR:-$HOME/Library/Application Support/hermetic-couch/_steam-provision}"
    steamapps="$root/prefix/drive_c/Program Files (x86)/Steam/steamapps"
    src="$steamapps/common/$folder"
    if [ ! -d "$src" ]; then
      echo "hermetic-couch: not found: $src" >&2
      echo "  provision + install it first: nix run .#hc-steam-provision" >&2
      exit 1
    fi

    # Read Steam's authoritative buildid; it doubles as the default version identity.
    acf="$steamapps/appmanifest_$appid.acf"
    buildid="unknown"
    if [ -f "$acf" ]; then
      found="$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$acf" | grep -oE '[0-9]+' | head -n1 || true)"
      [ -n "$found" ] && buildid="$found"
    fi
    version="''${version_arg:-$buildid}"
    if [ -z "$version" ] || [ "$version" = "unknown" ]; then
      echo "hermetic-couch: no buildid in $acf; pass a version explicitly:" >&2
      echo "  hc-capture $slug <version>" >&2
      exit 1
    fi
    echo "hermetic-couch: capturing $slug $version (appid $appid, folder '$folder', buildid $buildid)" >&2

    # Store names can't contain spaces, so re-name the dir to a clean slug-version. Hardlink
    # it (near-free) when on one filesystem; the only real copy is into the store.
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    dest="$tmp/$slug-$version"
    if ! cp -al "$src" "$dest" 2>/dev/null; then
      rm -rf "$dest"
      cp -a "$src" "$dest"
    fi

    echo "hermetic-couch: adding the game directory to the local store …" >&2
    storepath="$(nix-store --add-fixed --recursive sha256 "$dest")"
    hash="$(nix-hash --type sha256 --base32 "$dest")"

    {
      echo ""
      echo "added to store: $storepath"
      echo "Set play = \"$version\" and paste into games/$slug.nix:"
      echo ""
    } >&2
    echo "    versions.\"$version\" = { sha256 = \"$hash\"; buildid = \"$buildid\"; };"
  '';
}
