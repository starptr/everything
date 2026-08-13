// Gateway to the real Hono routes for in-process e2e. `server/routes/api.ts` imports
// `sessionManager.ts`, which statically imports the native `bun-pty`. No sandbox CUJ
// spawns a PTY (the create route's terminal spawn lives in a background branch that
// never runs here), so we stub `bun-pty` BEFORE importing the routes — the same
// technique the client behavioral test uses for the `Terminal` component. This is the
// only module that loads the routes, so the mock is always registered first.

import { mock } from "bun:test";

// Quiet the server's console during tests (also settable via the env before bun starts).
process.env.OPENUI_QUIET ??= "1";

mock.module("bun-pty", () => ({
  spawn: () => {
    throw new Error("bun-pty spawn is unavailable in sandbox e2e (no PTY should be spawned)");
  },
}));

const { apiRoutes } = await import("../../server/routes/api");
export { apiRoutes };

// Drive a route the way index.ts's mounted app would, minus the `/api` prefix (routes
// are rooted at `/` on apiRoutes). Returns the status + parsed JSON body.
export async function api(
  path: string,
  init?: RequestInit,
): Promise<{ status: number; body: any }> {
  const res = await apiRoutes.request(path, init);
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

// Convenience for JSON POST/PATCH bodies.
export function jsonInit(method: string, body: unknown): RequestInit {
  return {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}
