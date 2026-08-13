import type { IPty } from "bun-pty";
import type { ServerWebSocket } from "bun";

// A live-PTY registry entry — the ONE thing papyrus owns that silverwood cannot
// model (a running process, its WebSocket clients, and scrollback). Purely
// ephemeral: an entry exists iff a PTY is live. All durable data (session list,
// names, lock) is re-read from silverwood on demand — never cached here. Keyed in
// the registry by the claude session id: papyrus mints it via `--session-id` (or
// resumes via `--resume <id>`), so the runtime key === claude id === silverwood key.
export interface Session {
  pty: IPty;
  // The workstream this PTY belongs to (the registry is keyed by session id).
  workstreamId: string;
  cwd: string;
  clients: Set<ServerWebSocket<WebSocketData>>;
  outputBuffer: string[];
  // Whether this instance currently holds the session's advisory lock.
  holdsLock?: boolean;
  // The session variant this PTY runs. Both are durable silverwood session records;
  // "claude-code" (default) is a resumable agent session with an advisory lock,
  // "plain-shell" is a `silverwood spawn <ws>` login shell that carries no lock and
  // reopens as a fresh shell (there is no process to resume).
  kind?: "claude-code" | "plain-shell";
}

export interface LinearTicket {
  id: string;
  identifier: string;
  title: string;
  url: string;
  state: { name: string; color: string };
  priority: number;
  assignee?: { name: string };
  team?: { name: string; key: string };
}

// Linear settings are read from the environment only (never written to disk).
export interface LinearConfig {
  apiKey?: string;
  defaultTeamId?: string;
}

export interface Agent {
  id: string;
  name: string;
  command: string;
  description: string;
  color: string;
  icon: string;
}

export interface WebSocketData {
  sessionId: string;
}
