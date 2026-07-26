// How the reconcile loop resolves a canvas node's position against silverwood, which is
// the source of truth. The one exception is a node we just dragged locally: we keep its
// optimistic position (recorded as a move-guard) until our own save echoes back, so the
// poll never snaps a fresh drag back to the pre-drag value.

export interface XY {
  x: number;
  y: number;
}

// An optimistic-position guard for a locally-dragged node: the coordinate we saved, plus
// a safety expiry (a timestamp past which we stop waiting for the echo and trust silverwood).
export interface MoveGuard extends XY {
  expiry: number;
}

// Decide, for a node already on the canvas, whether to adopt silverwood's `server` position
// and whether to drop its move-guard. `local` is the node's current on-screen position.
//   - No guard: silverwood is authoritative — adopt it if it differs (this is how a move in
//     another instance shows up here).
//   - Guard matches `server`: our own save propagated — clear the guard (server == local, so
//     nothing to adopt).
//   - Guard set, `server` still stale, before expiry: keep the optimistic position.
//   - Guard set, past expiry: the save failed or was clobbered — clear the guard and adopt.
export function resolveReconciledPosition(
  local: XY,
  server: XY | undefined,
  guard: MoveGuard | undefined,
  now: number,
): { position?: XY; clearGuard: boolean } {
  if (!server || typeof server.x !== "number" || typeof server.y !== "number") {
    return { clearGuard: false };
  }
  let guarded = false;
  let clearGuard = false;
  if (guard) {
    if (guard.x === server.x && guard.y === server.y) {
      clearGuard = true; // our write propagated
    } else if (now > guard.expiry) {
      clearGuard = true; // save failed/clobbered → trust server
    } else {
      guarded = true;
    }
  }
  if (!guarded && (local.x !== server.x || local.y !== server.y)) {
    return { position: server, clearGuard };
  }
  return { clearGuard };
}
