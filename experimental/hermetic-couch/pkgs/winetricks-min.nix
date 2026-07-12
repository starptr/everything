# winetricks, packaged from its upstream single-file script with only the CLI tools it
# needs on PATH — deliberately GUI-less. nixpkgs' winetricks pulls in zenity (→ a GTK /
# libadwaita / appstream stack that's slow and fragile to build on darwin) purely for
# interactive dialogs; we only ever invoke it as `winetricks -q` (unattended), so that
# whole tree is dead weight. `$WINE`/`$WINEPREFIX` are supplied by the wine runner.
{
  stdenvNoCC,
  fetchurl,
  lib,
  makeWrapper,
  cabextract,
  p7zip,
  curl,
  unzip,
  coreutils,
  gnused,
  gnugrep,
  gawk,
  gnutar,
  gzip,
  which,
}:
{
  version,
  hash,
}:
stdenvNoCC.mkDerivation {
  pname = "winetricks-min";
  inherit version;

  src = fetchurl {
    url = "https://raw.githubusercontent.com/Winetricks/winetricks/${version}/src/winetricks";
    inherit hash;
  };
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/winetricks"
    wrapProgram "$out/bin/winetricks" --prefix PATH : ${
      lib.makeBinPath [
        cabextract
        p7zip
        curl
        unzip
        coreutils
        gnused
        gnugrep
        gawk
        gnutar
        gzip
        which
      ]
    }
    runHook postInstall
  '';

  meta = {
    description = "winetricks (upstream script), GUI-less, for unattended `-q` use";
    homepage = "https://github.com/Winetricks/winetricks";
    mainProgram = "winetricks";
    platforms = lib.platforms.all;
  };
}
