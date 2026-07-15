import type { IPty } from "bun-pty";
import type { ServerWebSocket } from "bun";

export type AgentStatus =
  | "running"
  | "waiting_input"
  | "tool_calling"
  | "idle"
  | "disconnected"
  | "error";

// Runtime-only state for a workstream's terminal. Ephemeral: everything here is
// rebuilt or discarded on restart. Durable state lives in silverwood.
export interface Session {
  pty: IPty | null;
  agentId: string;
  agentName: string;
  command: string;
  cwd: string;
  createdAt: string;
  clients: Set<ServerWebSocket<WebSocketData>>;
  outputBuffer: string[];
  status: AgentStatus;
  lastOutputTime: number;
  lastInputTime: number;
  recentOutputSize: number;
  isRestored?: boolean;
  // Live status reported by the Claude Code plugin's hooks.
  claudeSessionId?: string;
  currentTool?: string;
  preToolTime?: number;
  permissionTimeout?: ReturnType<typeof setTimeout>;
  pluginReportedStatus?: boolean;
  lastPluginStatusTime?: number;
  lastHookEvent?: string;
  // Whether a silverwood session has been recorded for claudeSessionId already.
  silverwoodSessionRecorded?: boolean;
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
