# papyrus GUI, re-exported from its own flake (experimental/papyrus). Like
# silverwood, papyrus lives only in this monorepo (not on GitHub), so there is
# no fetchFromGitHub fallback: it requires soup to be consumed as a flake (so
# `maybe-flake-inputs` is populated).
{ stdenv, maybe-flake-inputs }:
if maybe-flake-inputs == null then
  throw "papyrus is only available when soup is consumed as a flake (monorepo-only; no github fallback)"
else
  maybe-flake-inputs.papyrus.packages.${stdenv.hostPlatform.system}.default
