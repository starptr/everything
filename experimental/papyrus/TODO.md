# papyrus — TODO

The persistent progress tracker across agent/LLM sessions.
Legend: `[ ]` pending · `[~]` in progress · `[x]` done

## Part 0 — Vendor + package
- [x] Vendor `Fallomai/openui` @ `2963e59` into `experimental/papyrus` (see `VENDOR.md`)
- [x] Rebrand: `package.json` name/bin → papyrus; drop stale upstream URLs; remove
      prebuilt `.js` duplicates
- [x] `flake.nix` — bun2nix `writeBunApplication` (server) + client build; commit
      `bun.nix` + `client/bun.nix`
- [x] soup re-export (`git+file` input + `pkgs/papyrus.nix` + `extraPackages.nix`)

## Part 1 — Deploy (deferred)
- [ ] Wire papyrus onto sodium's PATH (silverwood-style soup consumption)

## Part 2 — silverwood integration (the point of papyrus)
- [ ] Read silverwood workstreams via `silverwood --json`; render as canvas nodes
- [ ] Map papyrus agent sessions ↔ silverwood agent sessions
- [ ] Replace openui's `.openui/state.json` model with silverwood-backed state

## Part 3 — Polish
- [ ] Deep UI rebrand (in-app OpenUI branding/copy → papyrus)
- [ ] Hermetic Claude-Code plugin (vendor `claude-code-plugin/` into the store; drop the
      runtime download in `bin/papyrus.ts`)
- [ ] Linux runtime (`autoPatchelfHook` for `bun-pty`'s `.so`)
