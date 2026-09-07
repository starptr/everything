# Milky-Way Secrets

**This directory is legacy and no longer used as the secret source.** It used to be the target for
sops-nix-generated symlinks that jsonnet imported via `milky-way/secrets/*`. Those in-repo bridge
symlinks were tied to a single everything-repo checkout and are unsafe under silverwood, so the
`.gitignore` here still ignores everything but this readme, but nothing writes here anymore.

The live source of truth is the sops-nix decryption store on whichever machine runs Tanka
(currently sodium: `~/.config/sops-nix/secrets/...`, from `magic/common/constants.nix`'s `secrets`
path). `milky-way/secrets.libsonnet` imports the decrypted files from there directly and exposes
their **content** (jsonnet forbids computed imports, so it can't expose a path map). Callers read
`(import 'milky-way/secrets.libsonnet')['<name>']` — see that file's header for the naming/layout
details (e.g. the `k8s-config/` subdir) and the TODO about de-hardcoding the absolute home path.

To add or change a secret: edit the sops source
(`secrets/k8s-config/k8s-secret-values.jsonnet` at the repo root), run `darwin-rebuild` on sodium so
sops-nix re-renders the decrypted store, then reference it from `secrets.libsonnet`. Do not add files
here.
