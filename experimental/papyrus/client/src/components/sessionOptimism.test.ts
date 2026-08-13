import { describe, test, expect } from "bun:test";
import {
  type PendingOptimism,
  shouldDropOptimism,
  mergePendingTabs,
} from "./sessionOptimism";
import type { SessionTab } from "../stores/useStore";

const tab = (over: Partial<SessionTab> = {}): SessionTab => ({
  sessionId: "s1",
  name: "claude",
  createdAt: "",
  kind: "claude-code",
  connected: false,
  ...over,
});
const opt = (ov: Partial<SessionTab>, seq = 0): PendingOptimism => ({ ov, seq });

describe("shouldDropOptimism", () => {
  test("connected optimism confirmed by the server → drop (any generation)", () => {
    expect(shouldDropOptimism(opt({ connected: true }, 5), tab({ connected: true }), 5)).toBe(true);
  });

  test("connected optimism unconfirmed, <2 reconciles elapsed → keep", () => {
    // server still shows connected:false (never observed true) and only 1 tick passed
    expect(shouldDropOptimism(opt({ connected: true }, 5), tab({ connected: false }), 6)).toBe(false);
  });

  test("connected optimism unconfirmed, ≥2 reconciles elapsed → drop (backstop)", () => {
    // the fast-fail race: server never showed connected:true, but the projection is now authoritative
    expect(shouldDropOptimism(opt({ connected: true }, 5), tab({ connected: false }), 7)).toBe(true);
  });

  test("name-only optimism: dropped on name match, never by the backstop", () => {
    expect(shouldDropOptimism(opt({ name: "new" }, 5), tab({ name: "new" }), 5)).toBe(true);
    // unmatched name + many generations elapsed: backstop does NOT apply to name-only → keep
    expect(shouldDropOptimism(opt({ name: "new" }, 5), tab({ name: "old" }), 99)).toBe(false);
  });

  test("missing tab (session vanished) → keep the override", () => {
    expect(shouldDropOptimism(opt({ connected: true }, 5), undefined, 99)).toBe(false);
  });
});

describe("mergePendingTabs", () => {
  test("override on an existing tab is merged over it", () => {
    const tabs = mergePendingTabs([tab({ sessionId: "s1", name: "old" })], {
      s1: opt({ name: "new" }),
    });
    expect(tabs).toHaveLength(1);
    expect(tabs[0].name).toBe("new");
  });

  test("override with no matching tab fabricates a tab (just-started session)", () => {
    const tabs = mergePendingTabs([], {
      s9: opt({ connected: true, name: "shell", kind: "plain-shell" }),
    });
    expect(tabs).toHaveLength(1);
    expect(tabs[0]).toMatchObject({ sessionId: "s9", name: "shell", kind: "plain-shell" });
  });

  // The bug this fixes: a rename override made in workstream A must not surface a
  // phantom tab in workstream B. Callers pass only the selected node's bucket, so
  // building B's tabs sees an empty `pending` and fabricates nothing.
  test("optimism scoped per workstream does not leak across workstreams", () => {
    const pendingByNode: Record<string, Record<string, PendingOptimism>> = {
      A: { shSid: opt({ name: "my shell", kind: "plain-shell" }) },
    };

    // Workstream A (which owns the shell) shows the renamed tab.
    const tabsA = mergePendingTabs(
      [tab({ sessionId: "shSid", name: "shell", kind: "plain-shell" })],
      pendingByNode["A"] ?? {},
    );
    expect(tabsA.find((t) => t.sessionId === "shSid")?.name).toBe("my shell");

    // Workstream B, selected next, gets an empty bucket → no phantom shell tab.
    const tabsB = mergePendingTabs(
      [tab({ sessionId: "bTab", name: "claude" })],
      pendingByNode["B"] ?? {},
    );
    expect(tabsB.map((t) => t.sessionId)).toEqual(["bTab"]);
  });
});
