# The frankea/Whisky prebuilt Wine bundle, relocated into the store as a single
# pinned artifact. This one tarball carries the whole lower Windows-game stack:
#   Wine/   — the wine build (arm64 + wow64; x86 Windows code runs under Rosetta 2)
#   DXMT/   — the D3D11→Metal DLLs, already installed into Wine/lib/wine as *builtin*
#             dlls (winemetal.so + d3d11/dxgi/winemetal.dll), so DXMT is the wine
#             builtin d3d11 with no prefix injection and an ABI-matched winemetal.
#   DXVK/   — the Vulkan/MoltenVK alternative (unused by the dxmt graphics path).
# We take no runtime dependency on Whisky.app — we orchestrate this wine ourselves
# (see runners/wine.nix). Signed binaries are relocated, never modified, so `dontFixup`
# keeps their signatures intact (nix sets no com.apple.quarantine, so Gatekeeper is a
# non-issue — DESIGN §7).
{
  stdenvNoCC,
  fetchurl,
  lib,
}:
{
  version,
  url,
  hash,
}:
stdenvNoCC.mkDerivation {
  pname = "whisky-wine";
  inherit version;

  src = fetchurl { inherit url hash; };

  # Prebuilt, signed Mach-O tree — do not strip, relink, or patch shebangs.
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  dontStrip = true;

  # Tarball root is "Libraries/"; keep the whole tree (Wine + DXMT + DXVK).
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out/"
    runHook postInstall
  '';

  meta = {
    description = "frankea/Whisky prebuilt Wine + DXMT bundle (relocated into the store)";
    homepage = "https://github.com/frankea/Whisky";
    platforms = lib.platforms.darwin;
  };
}
