# Fetch a single mod jar (e.g. from the Modrinth CDN), hash-pinned. The store name
# ends in .jar so runners can symlink it straight into a loader's mods/ directory.
{ pkgs, lib }:
{
  slug,
  version,
  url,
  sha256,
}:
pkgs.fetchurl {
  name = "${slug}-${version}.jar";
  inherit url sha256;
}
