import type { SessionTab } from "../stores/useStore";

// An optimistic tab override plus the reconcile generation at which it was applied. The
// sidebar shows `pending` overrides immediately (e.g. connect → `{connected:true}`) so the
// UI doesn't wait a reconcile; `seq` lets us retire the override even if the server never
// echoes the optimistic value.
export interface PendingOptimism {
  ov: Partial<SessionTab>;
  seq: number;
}

// Whether to drop an optimistic override, given the current server projection for its tab
// and the current reconcile generation. Drop once the server has caught up: it confirms
// every overridden field, OR — for a `connected` override — at least two reconciles have
// elapsed since it was set. Two reconciles guarantee a projection fetched strictly after the
// action was acknowledged, so the server's state is authoritative even if it never showed the
// optimistic value (the fast-fail case that otherwise sticks the tab as "connected"). The
// backstop is limited to `connected` overrides, so a rename settles on name-match only and
// never flickers. A missing tab (session vanished) keeps the override untouched.
export function shouldDropOptimism(
  entry: PendingOptimism,
  tab: SessionTab | undefined,
  seqNow: number,
): boolean {
  if (!tab) return false;
  const { ov, seq } = entry;
  const confirmed =
    (ov.connected === undefined || tab.connected === ov.connected) &&
    (ov.name === undefined || tab.name === ov.name);
  const backstop = ov.connected !== undefined && seqNow - seq >= 2;
  return confirmed || backstop;
}
