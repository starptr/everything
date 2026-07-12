# The complete, hermetic Minecraft payload as ONE content-addressed store path:
# the client jar, every vanilla library + native, the full asset set, and the mod
# loader's jars — everything needed to launch offline. This is a fixed-output
# derivation: it resolves + downloads via `portablemc start --dry` (network is allowed
# in FODs), then keeps only the deterministic, content-addressed trees. Pin `hash` once
# (build with lib.fakeHash, copy the reported hash); thereafter it's reproducible,
# offline, and cacheable via Cachix — the payload never touches the network again.
{
  stdenvNoCC,
  lib,
  portablemc,
  cacert,
}:
{
  minecraft,
  loader ? { kind = "vanilla"; },
  jre,
  hash,
}:
let
  kind = loader.kind or "vanilla";
  # portablemc installer selector, e.g. "fabric:1.21.1:0.16.10" or just "1.21.1".
  installerSel = if kind == "vanilla" then minecraft else "${kind}:${minecraft}:${loader.version}";
  label = if kind == "vanilla" then minecraft else "${minecraft}-${kind}-${loader.version}";
in
stdenvNoCC.mkDerivation {
  name = "minecraft-payload-${label}";

  nativeBuildInputs = [
    portablemc
    cacert
  ];

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = hash;

  buildCommand = ''
    export HOME="$TMPDIR"
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"

    work="$TMPDIR/mc"
    mkdir -p "$work"
    portablemc --main-dir "$work" start --dry --jvm ${jre}/bin/java ${installerSel}

    # Keep only the deterministic Mojang/loader content; drop the (empty) bin/ and any
    # launcher scratch. These three trees are all content-addressed downloads.
    mkdir -p "$out"
    cp -R "$work/versions" "$out/versions"
    cp -R "$work/libraries" "$out/libraries"
    cp -R "$work/assets" "$out/assets"
  '';
}
