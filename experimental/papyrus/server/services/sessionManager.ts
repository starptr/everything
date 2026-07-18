import { spawn as spawnPty } from "bun-pty";
import { hostname } from "os";
import { randomUUID } from "crypto";
import type { Session } from "../types";
import * as sw from "./silverwood";

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);

// This papyrus instance's advisory-lock holder token, fixed for the server's
// lifetime. The random suffix means a restarted papyrus (which may reuse a pid)
// never mistakes a lock left by a previous run for its own — it would force-steal
// deliberately instead.
export const HOLDER = `papyrus:${hostname()}:${process.pid}:${randomUUID().slice(0, 8)}`;

const MAX_BUFFER_SIZE = 1000;

// The in-memory live-PTY registry, keyed by the claude session id. An entry exists
// iff a PTY is live. Purely ephemeral — PTYs, WebSocket clients, and scrollback
// live here and vanish on restart. All durable state is in silverwood; nothing
// here is cached from it.
export const sessions = new Map<string, Session>();

// Release the advisory lock this instance holds for a session, if any
// (best-effort; a crash skips it and the lock is recovered via a force-steal).
// The registry key IS the silverwood session id.
function releaseLock(sessionKey: string, session: Session): void {
  if (session.holdsLock) {
    session.holdsLock = false;
    sw.sessionUnlock(session.workstreamId, sessionKey, HOLDER).catch((e) =>
      log(`\x1b[38;5;141m[lock]\x1b[0m release ${sessionKey}: ${e.message}`),
    );
  }
}

/// Spawn a terminal for a session: a bash PTY in the checkout dir that runs
/// `command` (`claude --session-id <id>` fresh, or `claude --resume <id>`).
/// Registered under `sessionKey` (the claude session id). On process exit,
/// releases the lock and drops the entry.
export function spawnTerminal(params: {
  sessionKey: string;
  workstreamId: string;
  cwd: string;
  command: string;
}): Session {
  const { sessionKey, workstreamId, cwd, command } = params;

  const ptyProcess = spawnPty("/bin/bash", [], {
    name: "xterm-256color",
    cwd,
    env: { ...process.env, TERM: "xterm-256color" },
    rows: 30,
    cols: 120,
  });

  const session: Session = {
    pty: ptyProcess,
    workstreamId,
    cwd,
    clients: new Set(),
    outputBuffer: [],
  };
  sessions.set(sessionKey, session);

  ptyProcess.onData((data: string) => {
    session.outputBuffer.push(data);
    if (session.outputBuffer.length > MAX_BUFFER_SIZE) session.outputBuffer.shift();
    for (const client of session.clients) {
      if (client.readyState === 1) {
        client.send(JSON.stringify({ type: "output", data }));
      }
    }
  });

  ptyProcess.onExit(() => {
    // Only tear down if this exact entry is still the live one for the key.
    if (sessions.get(sessionKey) === session) {
      releaseLock(sessionKey, session);
      session.clients.clear();
      sessions.delete(sessionKey);
      log(`\x1b[38;5;141m[terminal]\x1b[0m exited ${sessionKey}`);
    }
  });

  setTimeout(() => ptyProcess.write(`${command}\r`), 300);

  log(`\x1b[38;5;141m[terminal]\x1b[0m spawned ${sessionKey} in ${cwd}`);
  return session;
}

/// Resolve a runtime entry by its registry key (the claude session id).
export function resolveRuntime(id: string): [string, Session] | undefined {
  const s = sessions.get(id);
  return s ? [id, s] : undefined;
}

/// Tear down a session's terminal + registry entry, releasing its lock. Does NOT
/// touch silverwood's durable session record.
export function killTerminal(sessionKey: string): boolean {
  const session = sessions.get(sessionKey);
  if (!session) return false;
  releaseLock(sessionKey, session);
  session.pty.kill();
  session.clients.clear();
  sessions.delete(sessionKey);
  log(`\x1b[38;5;141m[terminal]\x1b[0m killed ${sessionKey}`);
  return true;
}

/// Kill runtime entries whose workstream no longer exists (archived/deleted
/// elsewhere), releasing their locks — keeps the registry a projection of the forest.
export function pruneWorkstreams(aliveWsIds: Set<string>): void {
  for (const [key, s] of [...sessions]) {
    if (!aliveWsIds.has(s.workstreamId)) killTerminal(key);
  }
}
