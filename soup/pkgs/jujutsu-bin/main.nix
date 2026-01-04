{ stdenvNoCC, fetchurl, lib, unzip, maybe-flake-inputs }:
let
  download = { version, target-triple, hash, extension }:
    let
      url = "https://github.com/jj-vcs/jj/releases/download/${version}/jj-${version}-${target-triple}.${extension}";
    in if extension == "zip" then
      fetchurl {
        inherit url;
        hash = hash;
      }
    else if extension == "tar.gz" then 
      builtins.fetchTarball {
        inherit url;
        sha256 = hash;
      }
    else
      throw "Unimplemented extension: ${extension}";
  bin = { version, target-triple, hash, extension }:
    let
      src = download { inherit version target-triple hash extension; };
    in stdenvNoCC.mkDerivation {
      inherit version src;
      sourceRoot = "./source";

      pname = "jujutsu-bin";

      installPhase = ''
        mkdir -p $out/bin
        cp ./jj $out/bin/jj
      '';

      meta = {
        description = "Jujutsu binary from the official GitHub release page";
        homepage = "https://github.com/jj-vcs/jj/releases";
        mainProgram = "jj";
      };
    };
in 
lib.fix (self: {
  v0_36_0 = {
    aarch64-darwin = bin {
      version = "v0.36.0";
      target-triple = "aarch64-apple-darwin";
      hash = "1hi6xc7z1nwcpm4cf08h7dalmvf7sy20v5ysrip2bjbsrrxirpaj";
      extension = "tar.gz";
    };
  };
  
  # Update this manually
  latest = self.v0_36_0;
})