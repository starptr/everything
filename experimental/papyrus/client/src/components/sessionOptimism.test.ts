import { describe, test, expect } from "bun:test";
import { type PendingOptimism, shouldDropOptimism } from "./sessionOptimism";
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
