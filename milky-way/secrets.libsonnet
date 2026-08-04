// Central registry for the sops-decrypted secrets that milky-way jsonnet consumes.
//
// These are read straight from the sops-nix decryption store on whichever machine runs Tanka
// (currently sodium: ~/.config/sops-nix/secrets -- the `secrets` home-relative path string in
// magic/common/constants.nix, and the sops `path` target set in
// venus/modules/home-manager/sodium.nix). We point at that store directly rather than at the
// old in-repo bridge symlinks (milky-way/secrets/*), which were tied to a single
// everything-repo checkout and are no longer safe under silverwood.
//
// jsonnet forbids computed imports ("Computed imports are not allowed"), so this file cannot
// expose a name -> path-string map for callers to `import`; instead it performs the literal
// import/importstr here and exposes name -> decrypted CONTENT. Callers reference
// `(import 'milky-way/secrets.libsonnet')['<name>']`.
//
// TODO: the absolute home path is hardcoded below. Eventually source it from magic
// (magic/common/constants.nix `secrets`) instead of hardcoding /Users/yuto/... -- which,
// given the computed-import restriction, will need Nix codegen or Tanka external variables
// rather than a plain `import`.
{
  'k8s-secret-values.jsonnet': import '/Users/yuto/.config/sops-nix/secrets/k8s-secret-values.jsonnet',
  'qbt-gluetun.conf': importstr '/Users/yuto/.config/sops-nix/secrets/qbt-gluetun.conf',
  'gluetun-vpn-proxy.conf': importstr '/Users/yuto/.config/sops-nix/secrets/gluetun-vpn-proxy.conf',
  'thelounge-gluetun.conf': importstr '/Users/yuto/.config/sops-nix/secrets/thelounge-gluetun.conf',
  'kubo-gluetun.conf': importstr '/Users/yuto/.config/sops-nix/secrets/kubo-gluetun.conf',
}
