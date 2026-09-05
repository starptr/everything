import type { SessionTab } from "../stores/useStore";

// Apply a user-chosen tab order (a list of session ids, persisted per workstream in
// papyrus KV) to the tab list. Tabs whose id is in `order` come first, in that order;
// tabs not in `order` (e.g. a just-created session) keep their existing relative order
// and land at the end. `Array.sort` is stable, so equal-rank (unknown) ids preserve
// input order. A missing/empty order returns the list unchanged.
export function orderTabs(tabs: SessionTab[], order: string[] | undefined): SessionTab[] {
  if (!order?.length) return tabs;
  const rank = new Map(order.map((id, i) => [id, i]));
  return [...tabs].sort(
    (a, b) => (rank.get(a.sessionId) ?? Infinity) - (rank.get(b.sessionId) ?? Infinity),
  );
}

// Positional equality of two id lists — used to retire a drag's optimistic order once
// the server echoes it back. Two `undefined`s are NOT equal (nothing to compare).
export function sameOrder(a: string[] | undefined, b: string[] | undefined): boolean {
  return !!a && !!b && a.length === b.length && a.every((x, i) => x === b[i]);
}

// Move `dragId` to `overId`'s slot within `ids` (drag-reorder). The dragged id takes
// the target's index and the rest shift to fill; returns `ids` unchanged if either id
// is absent or they're the same. Non-mutating.
export function moveWithinOrder(ids: string[], dragId: string, overId: string): string[] {
  const from = ids.indexOf(dragId);
  const to = ids.indexOf(overId);
  if (from === -1 || to === -1 || from === to) return ids;
  const next = [...ids];
  next.splice(from, 1);
  next.splice(to, 0, dragId);
  return next;
}
