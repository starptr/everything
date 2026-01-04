{ stdenvNoCC, fetchurl, lib, unzip, maybe-flake-inputs }:
let
  version = "11.5";
  src = if builtins.isNull maybe-flake-inputs
    then
      fetchurl {
        url = "https://github.com/love2d/love/releases/download/${version}/love-${version}-macos.zip";
        hash = "sha256-Z5W7OhZWr2ov3+dB4VB4e0gYhtOigDJ6Jho/3e1YaRM=";
      }
    else
      maybe-flake-inputs.love;
  sourceRoot = if builtins.isNull maybe-flake-inputs
    then
      "./love.app"
    else
      "./source"; # For some reason, flake inputs are extracted differently
in
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit version src sourceRoot;
  pname = "love";

  nativeBuildInputs = [ unzip ];

  installPhase = ''
    mkdir -p $out/{bin,Applications/love.app}
    cp -R . "$out/Applications/love.app"
    ln -s "$out/Applications/love.app/Contents/MacOS/love" "$out/bin/love"
  '';

  meta = {
    changelog = "";
    description = "Lua-based 2D game engine/scripting language";
    homepage = "https://love2d.org";
    mainProgram = "love";
    platforms = lib.platforms.darwin;
  };

})