import { spawn as spawnPty } from "bun-pty";
import { existsSync } from "fs";
import { join } from "path";
import { homedir, hostname } from "os";
import { randomUUID } from "crypto";
import { PORT, HOST } from "../config";
import type { Session } from "../types";
import * as sw from "./silverwood";

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);

// This papyrus instance's advisory-lock holder token, fixed for the server's
// lifetime. The random suffix means a restarted papyrus (which may reuse a pid)
// never mistakes a lock left by a previous run for its own — it would force-steal
// deliberately instead.
export const HOLDER = `papyrus:${hostname()}:${process.pid}:${randomUUID().slice(0, 8)}`;

// Locate the Claude Code plugin dir (adds the status hooks that drive node
// state). Installed under ~/.openui/claude-code-plugin, or vendored in-repo.
function getPluginDir(): string | null {
  const homePluginDir = join(homedir(), ".openui", "claude-code-plugin");
  if (existsSync(join(homePluginDir, ".claude-plugin", "plugin.json"))) {
    return homePluginDir;
  }
  const repoPluginDir = join(import.meta.dir || __dirname, "..", "..", "claude-code-plugin");
  if (existsSync(join(repoPluginDir, ".claude-plugin", "plugin.json"))) {
    return repoPluginDir;
  }
  return null;
}

// Inject `--plugin-dir` into a `claude` command so the plugin's hooks fire.
export function injectPluginDir(command: string, agentId: string): string {
  if (agentId !== "claude") return command;
  const pluginDir = getPluginDir();
  if (!pluginDir) return command;
  if (command.includes("--plugin-dir")) return command;
  const parts = command.split(/\s+/);
  if (parts[0] === "claude") {
    parts.splice(1, 0, "--plugin-dir", pluginDir);
    return parts.join(" ");
  }
  return command;
}

const MAX_BUFFER_SIZE = 1000;

// The in-memory live-PTY registry, keyed by runtime session key. An entry exists
// iff a PTY is live. Purely ephemeral — PTYs, WebSocket clients, scrollback, and
// live status all live here and vanish on restart. All durable state is in
// silverwood; nothing here is cached from it.
export const sessions = new Map<string, Session>();

// Release the advisory lock this instance holds for a session, if any
// (best-effort; a crash skips it and the lock is recovered via a force-steal).
function releaseLock(session: Session): void {
  if (session.holdsLock && session.claudeSessionId) {
    session.holdsLock = false;
    sw.sessionUnlock(session.workstreamId, session.claudeSessionId, HOLDER).catch((e) =>
      log(`\x1b[38;5;141m[lock]\x1b[0m release ${session.claudeSessionId}: ${e.message}`),
    );
  }
}

/// Spawn a terminal for a session: a bash PTY in the checkout dir that runs
/// `command` (`claude` fresh, or `claude --resume <id>`). Registered under
/// `sessionKey`. On process exit, releases the lock and drops the entry.
export function spawnTerminal(params: {
  sessionKey: string;
  workstreamId: string;
  cwd: string;
  command: string;
  claudeSessionId?: string;
  resumed?: boolean;
}): Session {
  const { sessionKey, workstreamId, cwd, command, claudeSessionId, resumed } = params;

  const ptyProcess = spawnPty("/bin/bash", [], {
    name: "xterm-256color",
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      // The plugin echoes this back on status hooks so we can correlate.
      OPENUI_SESSION_ID: sessionKey,
      // Tell the plugin's status-reporter where the server actually is (its
      // hardcoded fallback is a different port), so every status POST — which
      // carries the Claude session id we record — is not silently dropped.
      OPENUI_PORT: String(PORT),
      OPENUI_HOST: HOST,
    },
    rows: 30,
    cols: 120,
  });

  const session: Session = {
    pty: ptyProcess,
    workstreamId,
    cwd,
    clients: new Set(),
    outputBuffer: [],
    status: "running",
    lastOutputTime: Date.now(),
    lastInputTime: 0,
    recentOutputSize: 0,
    claudeSessionId,
    resumed: !!resumed,
    // A resumed session's silverwood record + lock already exist, so the status
    // hook must not re-record it.
    silverwoodSessionRecorded: !!resumed,
  };
  sessions.set(sessionKey, session);

  const resetInterval = setInterval(() => {
    if (sessions.get(sessionKey) !== session) {
      clearInterval(resetInterval);
      return;
    }
    session.recentOutputSize = Math.max(0, session.recentOutputSize - 50);
  }, 500);

  ptyProcess.onData((data: string) => {
    session.outputBuffer.push(data);
    if (session.outputBuffer.length > MAX_BUFFER_SIZE) session.outputBuffer.shift();
    session.lastOutputTime = Date.now();
    session.recentOutputSize += data.length;
    for (const client of session.clients) {
      if (client.readyState === 1) {
        client.send(JSON.stringify({ type: "output", data }));
      }
    }
  });

  ptyProcess.onExit(() => {
    clearInterval(resetInterval);
    // Only tear down if this exact entry is still the live one for the key.
    if (sessions.get(sessionKey) === session) {
      releaseLock(session);
      session.clients.clear();
      sessions.delete(sessionKey);
      log(`\x1b[38;5;141m[terminal]\x1b[0m exited ${sessionKey}`);
    }
  });

  const finalCommand = injectPluginDir(command, "claude");
  setTimeout(() => ptyProcess.write(`${finalCommand}\r`), 300);

  log(`\x1b[38;5;141m[terminal]\x1b[0m spawned ${sessionKey} in ${cwd}`);
  return session;
}

/// Resolve a runtime entry by its registry key, or by the claude session id it
/// carries (a fresh PTY is keyed by a provisional id but learns its claude id).
export function resolveRuntime(id: string): [string, Session] | undefined {
  const direct = sessions.get(id);
  if (direct) return [id, direct];
  for (const [key, s] of sessions) {
    if (s.claudeSessionId === id) return [key, s];
  }
  return undefined;
}

/// Tear down a session's terminal + registry entry, releasing its lock. Does NOT
/// touch silverwood's durable session record.
export function killTerminal(sessionKey: string): boolean {
  const session = sessions.get(sessionKey);
  if (!session) return false;
  releaseLock(session);
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
