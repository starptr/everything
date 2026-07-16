import { spawn as spawnPty } from "bun-pty";
import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { PORT, HOST } from "../config";
import type { Session } from "../types";

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);

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

// In-memory runtime state, keyed by silverwood workstream id. Purely ephemeral —
// PTYs, connected WebSocket clients, live status, and terminal scrollback all live
// here and are allowed to vanish on restart. All durable state is in silverwood.
export const sessions = new Map<string, Session>();

/// Ensure a (dormant) runtime entry exists for a workstream, so the WebSocket and
/// status endpoints can resolve it before its terminal is spawned. Records the
/// checkout `cwd` so a later spawn runs in the right directory.
export function ensureDormant(workstreamId: string, cwd = ""): Session {
  let session = sessions.get(workstreamId);
  if (!session) {
    session = {
      pty: null,
      agentId: "claude",
      agentName: "Claude Code",
      command: "claude",
      cwd,
      createdAt: new Date().toISOString(),
      clients: new Set(),
      outputBuffer: [],
      status: "disconnected",
      lastOutputTime: 0,
      lastInputTime: 0,
      recentOutputSize: 0,
      isRestored: true,
    };
    sessions.set(workstreamId, session);
  } else if (cwd && !session.cwd) {
    session.cwd = cwd;
  }
  return session;
}

/// Spawn a fresh terminal for a workstream: a bash PTY in the checkout dir that
/// runs `command` (e.g. `claude`). Reuses/updates the runtime entry. Returns it.
export function spawnTerminal(params: {
  workstreamId: string;
  cwd: string;
  agentId: string;
  agentName: string;
  command: string;
}): Session {
  const { workstreamId, cwd, agentId, agentName, command } = params;
  const session = ensureDormant(workstreamId, cwd);

  const ptyProcess = spawnPty("/bin/bash", [], {
    name: "xterm-256color",
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      // The plugin echoes this back on status hooks so we can correlate.
      OPENUI_SESSION_ID: workstreamId,
      // Tell the plugin's status-reporter where the server actually is. Without
      // this it falls back to its hardcoded 6969 while the server is on 6968, so
      // every status POST (which carries the Claude session id we record) is
      // silently dropped. Propagating the real port fixes it regardless of which
      // plugin copy loads (in-store vendored or a stale ~/.openui one).
      OPENUI_PORT: String(PORT),
      OPENUI_HOST: HOST,
    },
    rows: 30,
    cols: 120,
  });

  session.pty = ptyProcess;
  session.agentId = agentId;
  session.agentName = agentName;
  session.command = command;
  session.cwd = cwd;
  session.status = "running";
  session.isRestored = false;
  session.outputBuffer = [];
  session.lastOutputTime = Date.now();

  const resetInterval = setInterval(() => {
    if (!sessions.has(workstreamId) || !session.pty) {
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

  const finalCommand = injectPluginDir(command, agentId);
  setTimeout(() => ptyProcess.write(`${finalCommand}\r`), 300);

  log(`\x1b[38;5;141m[terminal]\x1b[0m spawned ${workstreamId} in ${cwd}`);
  return session;
}

/// Tear down a workstream's terminal + runtime entry. Does NOT touch silverwood.
export function killTerminal(workstreamId: string): boolean {
  const session = sessions.get(workstreamId);
  if (!session) return false;
  if (session.pty) session.pty.kill();
  session.clients.clear();
  sessions.delete(workstreamId);
  log(`\x1b[38;5;141m[terminal]\x1b[0m killed ${workstreamId}`);
  return true;
}
