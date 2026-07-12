# Generate a minimal macOS .app bundle in the store that launches `exec`.
# The CFBundleExecutable is a tiny shell stub (not a symlink — LaunchServices is
# unreliable with a symlinked main executable). Spotlight/Dock registration (copying
# the bundle into ~/Applications via mac-app-util) is deferred to Part 5; for now the
# bundle is `open`-able directly from the store path and symlinked into $out/bin.
{ pkgs, lib }:
{
  name,
  exec,
  displayName ? name,
  icon ? null,
  bundleId ? "couch.hermetic.${name}",
}:
let
  plist = pkgs.writeText "${name}-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key><string>${displayName}</string>
      <key>CFBundleDisplayName</key><string>${displayName}</string>
      <key>CFBundleExecutable</key><string>${name}</string>
      <key>CFBundleIdentifier</key><string>${bundleId}</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundleVersion</key><string>1</string>
      <key>CFBundleShortVersionString</key><string>1.0</string>
      <key>NSHighResolutionCapable</key><true/>${
        lib.optionalString (icon != null) ''

          <key>CFBundleIconFile</key><string>${name}.icns</string>''
      }
    </dict>
    </plist>
  '';

  stub = pkgs.writeShellScript name ''exec "${exec}" "$@"'';
in
pkgs.runCommand "${name}-app" { } ''
  app="$out/Applications/${displayName}.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp ${plist} "$app/Contents/Info.plist"
  cp ${stub} "$app/Contents/MacOS/${name}"
  chmod +x "$app/Contents/MacOS/${name}"
  ${lib.optionalString (icon != null) ''cp ${icon} "$app/Contents/Resources/${name}.icns"''}
  mkdir -p "$out/bin"
  ln -s "$app/Contents/MacOS/${name}" "$out/bin/${name}"
''
