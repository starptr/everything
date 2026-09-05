import { describe, test, expect } from "bun:test";
import { orderTabs, sameOrder, moveWithinOrder } from "./tabOrder";
import type { SessionTab } from "../stores/useStore";

const tab = (sessionId: string): SessionTab => ({
  sessionId,
  name: sessionId,
  createdAt: "",
  kind: "claude-code",
  connected: false,
});
const ids = (tabs: SessionTab[]) => tabs.map((t) => t.sessionId);

describe("orderTabs", () => {
  const tabs = [tab("a"), tab("b"), tab("c")];

  test("no/empty order → returns the list unchanged", () => {
    expect(orderTabs(tabs, undefined)).toBe(tabs);
    expect(orderTabs(tabs, [])).toBe(tabs);
  });

  test("full order reorders the tabs", () => {
    expect(ids(orderTabs(tabs, ["c", "a", "b"]))).toEqual(["c", "a", "b"]);
  });

  test("ids not in the order keep their relative order and land at the end", () => {
    // only "c" is ordered; "a"/"b" are unknown → appended in their original order
    expect(ids(orderTabs(tabs, ["c"]))).toEqual(["c", "a", "b"]);
    // "b" first, then the unknown "a","c" in input order
    expect(ids(orderTabs(tabs, ["b"]))).toEqual(["b", "a", "c"]);
  });

  test("stale ids in the order (deleted tabs) are ignored", () => {
    expect(ids(orderTabs(tabs, ["gone", "b", "a"]))).toEqual(["b", "a", "c"]);
  });

  test("does not mutate the input array", () => {
    const input = [tab("a"), tab("b")];
    orderTabs(input, ["b", "a"]);
    expect(ids(input)).toEqual(["a", "b"]);
  });

  test("empty tabs → empty result", () => {
    expect(orderTabs([], ["a", "b"])).toEqual([]);
  });
});

describe("moveWithinOrder", () => {
  const ids = ["a", "b", "c", "d"];
  test("move earlier → later takes the target slot", () => {
    expect(moveWithinOrder(ids, "a", "c")).toEqual(["b", "c", "a", "d"]);
  });
  test("move later → earlier takes the target slot", () => {
    expect(moveWithinOrder(ids, "d", "b")).toEqual(["a", "d", "b", "c"]);
  });
  test("same id or absent id → unchanged (same reference)", () => {
    expect(moveWithinOrder(ids, "a", "a")).toBe(ids);
    expect(moveWithinOrder(ids, "z", "b")).toBe(ids);
    expect(moveWithinOrder(ids, "a", "z")).toBe(ids);
  });
  test("does not mutate the input", () => {
    const input = ["a", "b", "c"];
    moveWithinOrder(input, "a", "c");
    expect(input).toEqual(["a", "b", "c"]);
  });
});

describe("sameOrder", () => {
  test("equal positionally", () => {
    expect(sameOrder(["a", "b"], ["a", "b"])).toBe(true);
  });
  test("different order or length", () => {
    expect(sameOrder(["a", "b"], ["b", "a"])).toBe(false);
    expect(sameOrder(["a"], ["a", "b"])).toBe(false);
  });
  test("undefined is never equal", () => {
    expect(sameOrder(undefined, ["a"])).toBe(false);
    expect(sameOrder(["a"], undefined)).toBe(false);
    expect(sameOrder(undefined, undefined)).toBe(false);
  });
});
