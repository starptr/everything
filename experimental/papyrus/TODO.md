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

## Part 1 — silverwood integration (the point of papyrus) — DONE
- [x] A canvas node IS a silverwood workstream; `silverwood --json ls` drives the canvas
- [x] All state in silverwood: coordinate/color/notes in `app.andref.papyrus` KV, name via
      `silverwood rename`, agent runs as silverwood sessions
- [x] Replace openui's `.openui/state.json` model — `server/services/silverwood.ts` is the
      sole persistence boundary; papyrus writes **nothing** to disk
- [x] silverwood-side: sessions refactored to reserved-namespace KV + kind-aware
      `silverwood session` wrapper + `silverwood rename` (doc schema v2)
- [x] Package: `silverwood` on papyrus's runtime PATH (flake `silverwood` input + PATH wrap)

## Part 2 — Deploy (deferred)
- [ ] Wire papyrus onto sodium's PATH (silverwood-style soup consumption)

## Part 3 — Polish / follow-ups
- [~] UI rebrand (header/modal/copy done; some upstream OpenUI strings + visuals remain)
- [ ] silverwood "adopt existing local directory" checkout mode, so a node can wrap a repo
      you already have (today a node must be an https URL silverwood clones)
- [ ] Async provisioning UX: `silverwood new` clones synchronously; show a live
      "provisioning" node instead of blocking the create request
- [ ] Re-home dropped features if wanted: canvas categories (needs forest-global state),
      terminal-scrollback persistence, Linear/worktree/ticket flow
- [ ] Register silverwood sessions for non-`claude-code` agents once more kinds exist
- [ ] Hermetic Claude-Code plugin (vendor `claude-code-plugin/` into the store; drop the
      runtime download in `bin/papyrus.ts`)
- [ ] Linux runtime (`autoPatchelfHook` for `bun-pty`'s `.so`)
