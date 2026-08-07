#!/usr/bin/env python3
"""vacuum-cleaner: remove the obsolete sops-nix bridge symlinks from THIS everything checkout.

These "Group A" symlinks were left behind by the everythingRepo/silverwood migration: milky-way and
the jupiter devshell now read secrets from the home store directly, so the in-repo bridge symlinks
are dead weight. Each is removed ONLY when all three hold:
  1. its path (relative to the repo root) exactly matches a known allowlist entry,
  2. it is actually a symlink, and
  3. it points at the expected (literal) sops-nix store target.
Anything else (missing / regular file / wrong target) is left untouched and reported.

The repo root is derived from this script's own location, so it operates on the checkout it lives in
regardless of the current working directory. Deletion requires --wet-run; --dry-run only previews.

    python3 experimental/vacuum-cleaner/main.py --dry-run
    python3 experimental/vacuum-cleaner/main.py --wet-run
"""

import os
import sys
from pathlib import Path

# <root>/experimental/vacuum-cleaner/main.py -> parents[2] == <root>.
REPO_ROOT = Path(__file__).resolve().parents[2]

# (path relative to repo root, expected raw symlink target). Targets are literal absolute strings
# on purpose -- this is the single place they live, and each is compared verbatim against readlink.
GROUP_A = [
    (".env.jupiter",                                       "/Users/yuto/.config/sops-nix/secrets/personal/jupiter.env"),
    ("jupiter/.env",                                       "/Users/yuto/.config/sops-nix/secrets/personal/jupiter.env"),
    ("milky-way/secrets/k8s-secret-values.jsonnet",        "/Users/yuto/.config/sops-nix/secrets/k8s-config/k8s-secret-values.jsonnet"),
    ("milky-way/secrets/qbt-gluetun.conf",                 "/Users/yuto/.config/sops-nix/secrets/k8s-config/qbt-gluetun.conf"),
    ("milky-way/secrets/gluetun-vpn-proxy.conf",           "/Users/yuto/.config/sops-nix/secrets/k8s-config/gluetun-vpn-proxy.conf"),
    ("milky-way/secrets/kubo-gluetun.conf",                "/Users/yuto/.config/sops-nix/secrets/k8s-config/kubo-gluetun.conf"),
    ("milky-way/secrets/thelounge-gluetun.conf",           "/Users/yuto/.config/sops-nix/secrets/k8s-config/thelounge-gluetun.conf"),
    ("milky-way/secrets/qbt-gluetun-US-CA-1001.conf",      "/Users/yuto/.config/sops-nix/secrets/k8s-config/qbt-gluetun.conf"),
    ("milky-way/secrets/gluetun-vpn-proxy-US-CA-645.conf", "/Users/yuto/.config/sops-nix/secrets/k8s-config/gluetun-vpn-proxy.conf"),
    ("milky-way/secrets/thelounge-gluetun-US-CA-849.conf", "/Users/yuto/.config/sops-nix/secrets/k8s-config/thelounge-gluetun.conf"),
]

USAGE = "usage: main.py (--dry-run | --wet-run)"


def parse_mode(argv):
    """Return True for wet-run, False for dry-run; exit if not exactly one mode flag was given."""
    dry = "--dry-run" in argv
    wet = "--wet-run" in argv
    extra = [a for a in argv if a not in ("--dry-run", "--wet-run")]
    if dry == wet or extra:  # neither/both flags, or any unrecognized argument
        sys.exit(f"{USAGE}\nexactly one of --dry-run or --wet-run is required")
    return wet


def main(argv):
    wet = parse_mode(argv)

    if not ((REPO_ROOT / ".jj").exists() or (REPO_ROOT / ".git").exists()):
        sys.exit(f"error: {REPO_ROOT} does not look like the everything checkout (no .jj/.git)")

    removed = skipped = 0
    for rel, expected in GROUP_A:
        p = REPO_ROOT / rel

        # (2) must be a symlink. is_symlink() uses lstat -> never follows; False if absent/regular.
        if not p.is_symlink():
            reason = "not a symlink" if os.path.lexists(p) else "not present"
            print(f"skip  {rel}: {reason}")
            skipped += 1
            continue

        # (3) must point at the expected target, compared raw against the literal allowlist value.
        actual = os.readlink(p)
        if actual != expected:
            print(f"skip  {rel}: points at {actual!r}, expected {expected!r}")
            skipped += 1
            continue

        if wet:
            p.unlink()  # removes the symlink itself, never its target
            print(f"rm    {rel} -> {actual}")
        else:
            print(f"would rm  {rel} -> {actual}")
        removed += 1

    verb = "removed" if wet else "would remove"
    print(f"\nvacuum-cleaner: {verb} {removed}, skipped {skipped}  (repo root: {REPO_ROOT})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
