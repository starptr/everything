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

// The tab list a workstream shows: its server projection (`storeTabs`) with local
// optimism merged over it. `pending` must be ONLY the selected workstream's overrides
// (sessionId → override) — callers scope it per node id — because the `else` branch
// fabricates a tab for an override whose id isn't in `storeTabs` (so a just-started
// session shows immediately). A cross-workstream override would otherwise materialize
// as a phantom tab here; scoping `pending` per workstream prevents that.
export function mergePendingTabs(
  storeTabs: SessionTab[],
  pending: Record<string, PendingOptimism>,
): SessionTab[] {
  const byId = new Map<string, SessionTab>(storeTabs.map((t) => [t.sessionId, { ...t }]));
  for (const [sid, { ov }] of Object.entries(pending)) {
    const ex = byId.get(sid);
    if (ex) byId.set(sid, { ...ex, ...ov });
    else
      byId.set(sid, {
        sessionId: sid,
        name: "claude",
        createdAt: new Date().toISOString(),
        kind: "claude-code",
        connected: true,
        lock: null,
        ...ov,
      });
  }
  return [...byId.values()];
}
