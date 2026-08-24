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
  // Whether any client has ever attached. The first attach replays scrollback verbatim (a
  // program may still be blocking on a query answer, e.g. fish waiting ~10s for DA1); later
  // attaches (reconnects, e.g. workstream switch-back) strip stale queries from the replay so
  // the fresh emulator does not re-answer them into an idle shell prompt.
  everConnected?: boolean;
  // Whether this instance currently holds the session's advisory lock.
  holdsLock?: boolean;
  // The silverwood session kind tag this PTY runs (from `session-schema`), recorded for
  // reference only — the PTY command is a uniform `spawn from-id`, so `kind` never shapes
  // it. claude-code* kinds are resumable agent sessions with an advisory lock; ephemeral
  // kinds (plain-shell, disk-space) carry no lock and reopen fresh. Defaults to "claude-code".
  kind?: string;
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
