# flake-profiles — per-machine system flakes & dev shells

Each `system-<machine>/` is a standalone flake that builds one host's system configuration;
the other dirs are dev-shell / build profiles (`everything-devenv`, `milky-way-devenv`,
`build-dns-config`, `whale`). `outputs.nix` wires the dev shells into the repo-root flake.

Two host families, **activated differently**:

- **Darwin (`system-sodium`)** — built and switched **locally** with `darwin-rebuild`.
- **Remote NixOS (`system-methanol`, and the other `system-*` Linux hosts)** — built locally
  and **pushed over SSH** with [deploy-rs](https://github.com/serokell/deploy-rs).

## Activating Sodium (Darwin)

```bash
# expansion of the `sdrs` shell alias (venus home-manager):
sudo darwin-rebuild switch --flake /Users/yuto/src/everything/flake-profiles/system-sodium

# dry build only (no activation, no sudo) — the `drb` alias:
darwin-rebuild build --flake /Users/yuto/src/everything/flake-profiles/system-sodium
```

`switch` needs **root** (hence `sudo`). sudo here is configured for Touch ID
(`security.pam.services.sudo_local.touchIdAuth`); when Touch ID isn't usable, authenticate with
your account **password** instead — run the command in an interactive terminal so sudo can prompt
(the non-interactive harness shell has no TTY for a password and would otherwise fall back to the
Touch ID dialog). The macOS `darwinConfigurations` attr is `"Yutos-Sodium"`.

x86_64-linux pieces (e.g. whale images) build via the `linux-builder` VM; if a switch fails with
`path '…' is not valid`, reset it: `nix run ./flake-profiles/system-sodium#reset-linux-builder`.

## Activating methanol (remote NixOS, via deploy-rs)

```bash
deploy ./flake-profiles/system-methanol --ssh-opts="-i ~/.ssh/id_rsa"
```

This builds `nixosConfigurations.methanol` (x86_64-linux — uses the Sodium `linux-builder` when
run from the Mac) and activates it on the node over SSH as `root@10.0.0.211`, with deploy-rs's
magic-rollback safety net (auto-reverts if the new generation can't confirm itself).

`--ssh-opts="-i ~/.ssh/id_rsa"` forces the connection to use that key. The 1Password SSH agent is
usually `$SSH_AUTH_SOCK` and will log `agent refused operation` lines — harmless, it just declines
and the `-i` key is used; passing `-i` (rather than relying on the agent) also avoids a Touch ID
prompt for the SSH connection. After a `services.k3s`/cluster-relevant change, see
`milky-way/CLAUDE.md` for any required post-activation rollouts (e.g. cilium).
