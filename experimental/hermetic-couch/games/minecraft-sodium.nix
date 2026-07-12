# Minecraft 1.21.1 + Fabric + Sodium — the Part 1 validation target (DESIGN §9.1).
# Sodium 0.6.0+ bundles the Fabric Rendering API, so it needs no Fabric API: a single
# mod. Launched via PrismLauncher (java runner), which handles MS auth + vanilla asset
# download on first run.
{
  pkgs,
  lib,
  hcLib,
}:
{
  runner = "java";
  displayName = "Minecraft (Sodium)";
  runnerConfig = {
    minecraft = "1.21.1";
    loader = {
      kind = "fabric";
      version = "0.16.10";
    };
    jre = pkgs.temurin-bin-21;
    # sha256 of the hermetic payload (client+libs+natives+assets+Fabric); see
    # pkgs/minecraft-payload.nix. Regenerate on any version/loader bump.
    payloadHash = "sha256-mHPM1YJWhV7ZSQG/ZnpcYthIgyPJo4eLW+jgUSGKKM8=";
    mods = [
      (hcLib.fetchMod {
        slug = "sodium";
        version = "mc1.21.1-0.6.0-fabric";
        url = "https://cdn.modrinth.com/data/AANobbMI/versions/b70slbHV/sodium-fabric-0.6.0%2Bmc1.21.1.jar";
        sha256 = "07phpdjw7l39jmqi8ihpplnznx9np978mqh5pnd2saxba8gkgcr1";
      })
    ];
  };
  settings = {
    renderDistance = 12;
    fullscreen = false;
  };
}
