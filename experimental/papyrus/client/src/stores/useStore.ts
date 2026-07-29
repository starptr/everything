import { create } from "zustand";
import type { Node } from "@xyflow/react";
import {
  type ThemeName,
  type ThemePreference,
  loadThemePreference,
  resolveTheme,
  saveThemePreference,
  systemPrefersDark,
} from "../theme";
import {
  type BackendId,
  clampLineSpacing,
  loadLineSpacing,
  loadTerminalBackend,
  saveLineSpacing,
  saveTerminalBackend,
} from "../settings";

// Resolved theme to start from: trust the pre-paint script's `data-theme` (set in
// index.html before first paint), falling back to resolving the stored preference.
function initialResolvedTheme(pref: ThemePreference): ThemeName {
  const fromDom =
    typeof document !== "undefined" ? document.documentElement.dataset.theme : undefined;
  return fromDom || resolveTheme(pref, systemPrefersDark());
}

export interface Agent {
  id: string;
  name: string;
  command: string;
  description: string;
  color: string;
  icon: string;
}

// One attached silverwood session = one tab. Projected from `session ls` + the
// server's live-PTY overlay + the advisory lock. `sessionId` is the durable claude
// session id — the WebSocket key and the id to resume.
export interface SessionTab {
  sessionId: string;
  name: string;
  createdAt: string;
  kind: string;
  connected: boolean;
  lock?: { holder: string; mine: boolean } | null;
  // Set on a disconnected tab whose last resume failed with "no conversation found".
  // `doctorKind` is the variant `silverwood session doctor` reported; the delete-session
  // button shows only when reason is "no-conversation" AND doctorKind is "claude-code".
  disconnectReason?: string;
  doctorKind?: string;
}

export interface AgentSession {
  id: string;
  sessionId: string;
  agentId: string;
  agentName: string;
  command: string;
  color: string;
  createdAt: string;
  cwd: string;
  originalCwd?: string; // Mother repo path when using worktrees
  gitBranch?: string;
  // Node visuals: any session connected in this papyrus instance, + checkout state.
  connected: boolean;
  checkoutState?: string;
  customName?: string;
  customColor?: string;
  notes?: string;
  // The workstream's attached sessions, one tab each (server projection).
  tabs?: SessionTab[];
  // Linear ticket info
  ticketId?: string;
  ticketTitle?: string;
}

interface AppState {
  // Config
  launchCwd: string;
  setLaunchCwd: (cwd: string) => void;
  // Backend listen port (from /api/config), used to open the terminal WebSocket
  // directly at the backend rather than via the page origin. Null until config loads.
  serverPort: number | null;
  setServerPort: (port: number | null) => void;

  // Agents
  agents: Agent[];
  setAgents: (agents: Agent[]) => void;

  // Sessions / Nodes
  sessions: Map<string, AgentSession>;
  addSession: (nodeId: string, session: AgentSession) => void;
  updateSession: (nodeId: string, updates: Partial<AgentSession>) => void;
  removeSession: (nodeId: string) => void;

  // Canvas
  nodes: Node[];
  setNodes: (nodes: Node[]) => void;
  addNode: (node: Node) => void;
  updateNode: (nodeId: string, updates: Partial<Node>) => void;
  removeNode: (nodeId: string) => void;

  // UI State
  selectedNodeId: string | null;
  setSelectedNodeId: (id: string | null) => void;
  sidebarOpen: boolean;
  setSidebarOpen: (open: boolean) => void;
  addAgentModalOpen: boolean;
  setAddAgentModalOpen: (open: boolean) => void;
  newSessionModalOpen: boolean;
  setNewSessionModalOpen: (open: boolean) => void;
  newSessionForNodeId: string | null;
  setNewSessionForNodeId: (nodeId: string | null) => void;
  settingsOpen: boolean;
  setSettingsOpen: (open: boolean) => void;

  // Theme
  themePreference: ThemePreference;
  setThemePreference: (pref: ThemePreference) => void;
  resolvedTheme: ThemeName;
  setResolvedTheme: (name: ThemeName) => void;

  // Terminal appearance
  terminalBackend: BackendId;
  setTerminalBackend: (id: BackendId) => void;
  lineSpacing: number;
  setLineSpacing: (value: number) => void;
}

export const useStore = create<AppState>((set) => ({
  // Config
  launchCwd: "",
  setLaunchCwd: (cwd) => set({ launchCwd: cwd }),
  serverPort: null,
  setServerPort: (port) => set({ serverPort: port }),

  // Agents
  agents: [],
  setAgents: (agents) => set({ agents }),

  // Sessions
  sessions: new Map(),
  addSession: (nodeId, session) =>
    set((state) => {
      const newSessions = new Map(state.sessions);
      newSessions.set(nodeId, session);
      return { sessions: newSessions };
    }),
  updateSession: (nodeId, updates) =>
    set((state) => {
      const newSessions = new Map(state.sessions);
      const session = newSessions.get(nodeId);
      if (session) {
        newSessions.set(nodeId, { ...session, ...updates });
      }
      return { sessions: newSessions };
    }),
  removeSession: (nodeId) =>
    set((state) => {
      const newSessions = new Map(state.sessions);
      newSessions.delete(nodeId);
      return { sessions: newSessions };
    }),

  // Canvas
  nodes: [],
  setNodes: (nodes) => set({ nodes }),
  addNode: (node) => set((state) => ({ nodes: [...state.nodes, node] })),
  updateNode: (nodeId, updates) =>
    set((state) => ({
      nodes: state.nodes.map((n) =>
        n.id === nodeId ? { ...n, ...updates } : n
      ),
    })),
  removeNode: (nodeId) =>
    set((state) => ({
      nodes: state.nodes.filter((n) => n.id !== nodeId),
    })),

  // UI State
  selectedNodeId: null,
  setSelectedNodeId: (id) => set({ selectedNodeId: id }),
  sidebarOpen: false,
  setSidebarOpen: (open) => set({ sidebarOpen: open }),
  addAgentModalOpen: false,
  setAddAgentModalOpen: (open) => set({ addAgentModalOpen: open }),
  newSessionModalOpen: false,
  setNewSessionModalOpen: (open) => set({ newSessionModalOpen: open }),
  newSessionForNodeId: null,
  setNewSessionForNodeId: (nodeId) => set({ newSessionForNodeId: nodeId }),
  settingsOpen: false,
  setSettingsOpen: (open) => set({ settingsOpen: open }),

  // Theme: preference persists to localStorage; `resolvedTheme` is the concrete theme
  // name (light/dark) that useThemeController applies to <html> and keeps in sync.
  themePreference: loadThemePreference(),
  setThemePreference: (pref) => {
    saveThemePreference(pref);
    set({ themePreference: pref });
  },
  resolvedTheme: initialResolvedTheme(loadThemePreference()),
  setResolvedTheme: (name) => set({ resolvedTheme: name }),

  // Terminal appearance: both persist to localStorage. Terminal reads lineSpacing live;
  // switching terminalBackend remounts the pane on the other emulator.
  terminalBackend: loadTerminalBackend(),
  setTerminalBackend: (id) => {
    saveTerminalBackend(id);
    set({ terminalBackend: id });
  },
  lineSpacing: loadLineSpacing(),
  setLineSpacing: (value) => {
    const clamped = clampLineSpacing(value);
    saveLineSpacing(clamped);
    set({ lineSpacing: clamped });
  },
}));
