import type { IPty } from "bun-pty";
import type { ServerWebSocket } from "bun";

export type AgentStatus =
  | "running"
  | "waiting_input"
  | "tool_calling"
  | "idle"
  | "disconnected"
  | "error";

// A live-PTY registry entry — the ONE thing papyrus owns that silverwood cannot
// model (a running process, its clients, scrollback, and live status). Purely
// ephemeral: an entry exists iff a PTY is live. All durable data (session list,
// names, lock) is re-read from silverwood on demand — never cached here. Keyed in
// the registry by the runtime session key (the claude session id for a resumed
// session; a provisional uuid for a fresh one until the plugin reports its id).
export interface Session {
  pty: IPty;
  // The workstream this PTY belongs to (the registry is no longer keyed by it).
  workstreamId: string;
  cwd: string;
  clients: Set<ServerWebSocket<WebSocketData>>;
  outputBuffer: string[];
  status: AgentStatus;
  lastOutputTime: number;
  lastInputTime: number;
  recentOutputSize: number;
  // The claude session id: known up front for a resumed session, learned from the
  // plugin hook for a fresh one. Used for reconciliation, recording, and the lock.
  claudeSessionId?: string;
  // Spawned via `--resume` (its silverwood session + lock already exist).
  resumed: boolean;
  // Whether a silverwood session has been recorded for claudeSessionId already.
  silverwoodSessionRecorded: boolean;
  // Whether this instance currently holds the advisory lock for claudeSessionId.
  holdsLock?: boolean;
  // Live status reported by the Claude Code plugin's hooks.
  currentTool?: string;
  preToolTime?: number;
  permissionTimeout?: ReturnType<typeof setTimeout>;
  pluginReportedStatus?: boolean;
  lastPluginStatusTime?: number;
  lastHookEvent?: string;
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
