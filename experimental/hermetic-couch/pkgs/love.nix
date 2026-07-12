# LÖVE 2D game engine — prebuilt macOS .app, installed + bin-symlinked.
# Mirrors soup/pkgs/love/default.nix (same upstream zip + hash).
{
  stdenvNoCC,
  fetchurl,
  lib,
  unzip,
}:
stdenvNoCC.mkDerivation {
  pname = "love";
  version = "11.5";

  src = fetchurl {
    url = "https://github.com/love2d/love/releases/download/11.5/love-11.5-macos.zip";
    hash = "sha256-Z5W7OhZWr2ov3+dB4VB4e0gYhtOigDJ6Jho/3e1YaRM=";
  };
  sourceRoot = "love.app";

  nativeBuildInputs = [ unzip ];

  installPhase = ''
    mkdir -p $out/{bin,Applications/love.app}
    cp -R . "$out/Applications/love.app"
    ln -s "$out/Applications/love.app/Contents/MacOS/love" "$out/bin/love"
  '';

  meta = {
    description = "Lua-based 2D game engine";
    homepage = "https://love2d.org";
    mainProgram = "love";
    platforms = lib.platforms.darwin;
  };
}
