import { spawn as spawnPty } from "bun-pty";
import { hostname } from "os";
import { randomUUID } from "crypto";
import type { Session } from "../types";
import * as sw from "./silverwood";

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);

// Resolve the silverwood binary to an absolute path once, so the PTY can exec it
// without a PATH in the minimal seed env below. A bare name is searched for on
// PATH now; if that fails we fall back to the name and let the spawn surface it.
const SILVERWOOD_EXE = sw.SILVERWOOD_BIN.includes("/")
  ? sw.SILVERWOOD_BIN
  : Bun.which(sw.SILVERWOOD_BIN) ?? sw.SILVERWOOD_BIN;

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

// Claude Code prints this to the PTY when `claude --resume <id>` finds no saved
// conversation, then exits. It's the only signal that a reconnect failed because
// the session was never persisted (created but never prompted) — Claude emits no
// structured status and the plugin hooks were removed. Brittle to Claude's wording;
// this is the single place to update if it changes.
const NO_CONVERSATION_MARKER = "No conversation found with session ID";

// Why a session's PTY last exited, when it was the resumable-but-missing case above.
// Populated on exit (keyed by session id) and cleared on the next spawn for that key
// or when the doctor endpoint acts. `doctorKind` is filled in from `session doctor`
// (the authority for the variant used to gate papyrus's delete-session button); it's
// absent until that async call lands. Ephemeral, like the registry itself.
export const disconnectInfo = new Map<
  string,
  { reason: "no-conversation"; doctorKind?: string }
>();

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

// The minimal, explicit environment handed to `silverwood spawn`. NOT papyrus's
// inherited devshell env (`{ ...process.env }`, which is polluted with
// IN_NIX_SHELL/DEVENV_*/an augmented PATH): silverwood scrubs and rebuilds the
// real login env from this seed before it execs the agent, so none of papyrus's
// env reaches claude. HOME/USER/SHELL seed that reconstruction; SSH_AUTH_SOCK is
// forwarded into it; SILVERWOOD_FOREST_PATH lets `spawn` resolve the same forest
// papyrus's other silverwood calls do (all consumed by silverwood, then scrubbed).
function seedEnv(): Record<string, string> {
  const env: Record<string, string> = { TERM: "xterm-256color" };
  for (const k of ["HOME", "USER", "LOGNAME", "SHELL", "SSH_AUTH_SOCK", "SILVERWOOD_FOREST_PATH"]) {
    const v = process.env[k];
    if (v) env[k] = v;
  }
  return env;
}

/// Spawn a terminal for a session: a PTY running `silverwood spawn` in the checkout
/// dir, registered under `sessionKey`. silverwood owns *how* the shell is created —
/// it scrubs the environment and picks the command from the checkout mode — and
/// `exec`s it, so this PTY tracks the shell's lifetime directly: when it exits the
/// PTY exits and we tear down (releasing the lock, dropping the entry).
///
/// Two variants:
///  - "claude-code" (default): `silverwood spawn <ws> <sid> [--resume]` — the agent
///    shell (`claude --session-id`/`--resume <id>`). `sessionKey` IS the claude
///    session id, so the registry key === claude id === silverwood key.
///  - "plain-shell": `silverwood spawn <ws>` (no session id) — a login shell.
///    `sessionKey` is a papyrus-local key used only for the registry/WebSocket and to
///    key the durable record; it is never passed to silverwood, and `resume` is
///    ignored (a shell has no process to resume — reopening spawns a fresh one).
export function spawnTerminal(params: {
  sessionKey: string;
  workstreamId: string;
  cwd: string;
  resume: boolean;
  kind?: "claude-code" | "plain-shell";
}): Session {
  const { sessionKey, workstreamId, cwd, resume, kind = "claude-code" } = params;

  // A fresh spawn attempt supersedes any prior "no conversation" verdict for this id.
  disconnectInfo.delete(sessionKey);

  const args =
    kind === "plain-shell"
      ? ["spawn", workstreamId]
      : ["spawn", workstreamId, sessionKey, ...(resume ? ["--resume"] : [])];

  const ptyProcess = spawnPty(SILVERWOOD_EXE, args, {
    name: "xterm-256color",
    cwd,
    env: seedEnv(),
    rows: 30,
    cols: 120,
  });

  const session: Session = {
    pty: ptyProcess,
    workstreamId,
    cwd,
    clients: new Set(),
    outputBuffer: [],
    kind,
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
      // A claude-code resume that failed because the conversation was never saved
      // exits printing NO_CONVERSATION_MARKER. Record it so the disconnected screen
      // can offer to clean up the orphaned session, and ask `session doctor` for the
      // variant (its authority) to gate that button.
      if (kind === "claude-code" && session.outputBuffer.join("").includes(NO_CONVERSATION_MARKER)) {
        disconnectInfo.set(sessionKey, { reason: "no-conversation" });
        sw.sessionDoctor(workstreamId, sessionKey)
          .then((r) => {
            const info = disconnectInfo.get(sessionKey);
            if (info) info.doctorKind = r.kind;
          })
          .catch((e) => log(`\x1b[38;5;141m[doctor]\x1b[0m ${sessionKey}: ${e.message}`));
      }
      releaseLock(sessionKey, session);
      session.clients.clear();
      sessions.delete(sessionKey);
      log(`\x1b[38;5;141m[terminal]\x1b[0m exited ${sessionKey}`);
    }
  });

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
