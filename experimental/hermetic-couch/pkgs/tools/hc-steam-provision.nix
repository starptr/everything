# hc-steam-provision — the NON-hermetic provisioning step (DESIGN §9.2 step 2). Boots
# Steam inside a SCRATCH wine prefix built from the pinned wine+DXMT env, so you can log
# in and install your games. The installed bits land in this runtime dir (a shared Steam
# library under ~/Library/Application Support/hermetic-couch/_steam-provision), NEVER in
# the store — `hc-capture` content-addresses them afterwards. Run it, log in, install,
# quit Steam, then capture. Impure by design (network + interactive login).
{
  writeShellApplication,
  coreutils,
  curl,
  whiskyWine,
  winetricks,
  steamSetupUrl ? "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe",
}:
writeShellApplication {
  name = "hc-steam-provision";
  runtimeInputs = [
    coreutils
    curl
    winetricks
  ];
  text = ''
    root="''${HC_PROVISION_DIR:-$HOME/Library/Application Support/hermetic-couch/_steam-provision}"
    prefix="$root/prefix"
    mkdir -p "$root"
    export WINEPREFIX="$prefix"
    export XDG_CACHE_HOME="$root/cache"
    mkdir -p "$XDG_CACHE_HOME"
    export WINE="${whiskyWine}/Wine/bin/wine"
    export WINESERVER="${whiskyWine}/Wine/bin/wineserver"
    export WINEARCH=win64
    export WINEDEBUG="''${WINEDEBUG:-fixme-all}"
    export PATH="${whiskyWine}/Wine/bin:$PATH"

    if ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      echo "hermetic-couch: WARNING — Rosetta 2 not installed; x86 game code won't run." >&2
      echo "  Install it once: softwareupdate --install-rosetta --agree-to-license" >&2
    fi

    if [ ! -d "$prefix/drive_c" ]; then
      echo "hermetic-couch: initializing provisioning prefix…"
      WINEDLLOVERRIDES="mscoree,mshtml=" "${whiskyWine}/Wine/bin/wine" wineboot -u
      "${whiskyWine}/Wine/bin/wineserver" -w
    fi

    if ! grep -qxF vcrun2022 "$root/.hc-winetricks" 2>/dev/null; then
      echo "hermetic-couch: applying winetricks verb 'vcrun2022'…"
      winetricks -q -f vcrun2022
      echo vcrun2022 >> "$root/.hc-winetricks"
    fi

    steamexe="$prefix/drive_c/Program Files (x86)/Steam/steam.exe"
    if [ ! -f "$steamexe" ]; then
      echo "hermetic-couch: installing Steam into the provisioning prefix (one-time)…"
      setup="$root/SteamSetup.exe"
      [ -f "$setup" ] || curl -fsSL -o "$setup" "${steamSetupUrl}"
      "${whiskyWine}/Wine/bin/wine" "$setup" /S
      "${whiskyWine}/Wine/bin/wineserver" -w
    fi

    echo "hermetic-couch: booting Steam — LOG IN and INSTALL your game(s)."
    echo "  When a game has finished installing, capture it (bits stay per-user, unfree):"
    echo "    nix run .#hc-capture -- <name> <version> <appid> [steam-folder-name]"
    exec "${whiskyWine}/Wine/bin/wine" "C:/Program Files (x86)/Steam/steam.exe"
  '';
}
