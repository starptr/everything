// UNIT test (mine to maintain — see ../../../TESTING.md): the session-schema → menu-row
// expansion. silverwood is the source of truth for kinds; row titles are the kind tag and
// descriptions are silverwood's `about`. A required bool option expands into two rows.
import { describe, test, expect } from "bun:test";
import {
  expandKindToRows,
  schemaToRows,
  kindPresentation,
  FALLBACK_SESSION_SCHEMA,
  type SessionKindInfo,
} from "./sessionSchema";

describe("expandKindToRows", () => {
  test("a kind with no options → one row titled by its tag, carrying empty options", () => {
    const rows = expandKindToRows({ kind: "plain-shell", description: "A shell.", options: [] });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: "plain-shell",
      options: {},
      label: "plain-shell",
      description: "A shell.",
    });
    expect(rows[0].disabled).toBeUndefined();
  });

  test("titles and descriptions come from silverwood (tag + its about), not invented labels", () => {
    const rows = expandKindToRows({
      kind: "disk-space",
      description: "A disk-space monitor session (a `df` refresh loop).",
      options: [],
    });
    expect(rows[0].label).toBe("disk-space");
    expect(rows[0].description).toBe("A disk-space monitor session (a `df` refresh loop).");
  });

  test("a required bool option → two rows, one per true/false, differentiated by the flag name", () => {
    const noni = FALLBACK_SESSION_SCHEMA.find((k) => k.kind === "claude-code-noninteractive")!;
    const rows = expandKindToRows(noni);
    expect(rows).toHaveLength(2);
    const byExec = Object.fromEntries(rows.map((r) => [r.options["run-direnv-exec"], r]));
    expect(byExec["true"]).toBeDefined();
    expect(byExec["false"]).toBeDefined();
    // Title stays the silverwood tag, with the chosen flag appended (no invented wording).
    expect(byExec["true"].label).toBe("claude-code-noninteractive (run-direnv-exec=true)");
    expect(byExec["false"].label).toBe("claude-code-noninteractive (run-direnv-exec=false)");
    expect(rows[0].key).not.toBe(rows[1].key);
  });

  test("an unknown kind still renders, titled by its tag with a generic icon", () => {
    const rows = expandKindToRows({ kind: "future-kind", description: "New.", options: [] });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: "future-kind", label: "future-kind", icon: "terminal" });
  });

  test("a required non-bool option → one disabled row (a flat click can't collect text)", () => {
    const k: SessionKindInfo = {
      kind: "needs-text",
      description: "…",
      options: [{ long: "branch", help: "", required: true, value_kind: "string" }],
    };
    const rows = expandKindToRows(k);
    expect(rows).toHaveLength(1);
    expect(rows[0].disabled).toBe(true);
    expect(rows[0].description).toContain("--branch");
  });

  test("a non-required option is not surfaced as a row dimension", () => {
    const k: SessionKindInfo = {
      kind: "opt",
      description: "…",
      options: [{ long: "verbose", help: "", required: false, value_kind: "bool" }],
    };
    const rows = expandKindToRows(k);
    expect(rows).toHaveLength(1);
    expect(rows[0].options).toEqual({});
  });
});

describe("schemaToRows", () => {
  test("expands the fallback schema in kind order (noninteractive → 2 rows)", () => {
    const rows = schemaToRows(FALLBACK_SESSION_SCHEMA);
    // 4 kinds, one of which (noninteractive) yields 2 rows → 5 rows.
    expect(rows).toHaveLength(5);
    expect(rows.map((r) => r.kind)).toEqual([
      "claude-code",
      "plain-shell",
      "claude-code-noninteractive",
      "claude-code-noninteractive",
      "disk-space",
    ]);
  });
});

describe("kindPresentation", () => {
  test("known kinds carry an icon; unknown kinds fall back to a generic terminal icon", () => {
    expect(kindPresentation("claude-code").icon).toBe("sparkles");
    expect(kindPresentation("disk-space").icon).toBe("cpu");
    expect(kindPresentation("mystery")).toEqual({ icon: "terminal" });
  });
});
