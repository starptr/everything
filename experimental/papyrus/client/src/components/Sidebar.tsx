import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import {
  X,
  Terminal as TerminalIcon,
  Clock,
  Folder,
  Edit3,
  Plus,
  Plug,
  Power,
  Lock,
  Loader2,
  Sparkles,
  Code,
  Cpu,
  Zap,
  Rocket,
  Bot,
  Brain,
  Wand2,
  GitBranch,
} from "lucide-react";
import { useStore, SessionTab } from "../stores/useStore";
import { Terminal } from "./Terminal";
import { NewSessionMenu } from "./NewSessionMenu";
import { useResizablePane } from "./useResizablePane";

const presetColors = [
  "#F97316", "#22C55E", "#3B82F6", "#8B5CF6", "#EC4899", "#EF4444", "#FBBF24", "#14B8A6"
];

const iconOptions = [
  { id: "sparkles", icon: Sparkles, label: "Sparkles" },
  { id: "code", icon: Code, label: "Code" },
  { id: "cpu", icon: Cpu, label: "CPU" },
  { id: "zap", icon: Zap, label: "Zap" },
  { id: "rocket", icon: Rocket, label: "Rocket" },
  { id: "bot", icon: Bot, label: "Bot" },
  { id: "brain", icon: Brain, label: "Brain" },
  { id: "wand2", icon: Wand2, label: "Wand" },
];

// The tab title is silverwood's session `name`, verbatim.
function tabLabel(t: SessionTab): string {
  return t.name;
}

export function Sidebar() {
  const {
    sidebarOpen,
    setSidebarOpen,
    selectedNodeId,
    sessions,
    setSelectedNodeId,
    updateSession,
    updateNode,
    nodes,
    agents,
  } = useStore();

  const session = selectedNodeId ? sessions.get(selectedNodeId) : null;
  const node = selectedNodeId ? nodes.find((n) => n.id === selectedNodeId) : null;

  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editNotes, setEditNotes] = useState("");
  const [editColor, setEditColor] = useState("");
  const [editIcon, setEditIcon] = useState("");

  // Drag-resizable pane width (persisted). Lives outside the AnimatePresence
  // subtree so it survives the pane closing/reopening.
  const { width, dragging, gripProps } = useResizablePane({
    storageKey: "papyrus:sidebarWidth",
    defaultWidth: 512,
    min: 360,
    max: 1200,
  });

  const [activeTabId, setActiveTabId] = useState<string | undefined>(undefined);
  // The session whose rename panel is open (its pencil was clicked), + its buffer.
  const [editingSessionId, setEditingSessionId] = useState<string | null>(null);
  const [editSessionName, setEditSessionName] = useState("");
  // Optimism: an action's server-confirmed result, shown until the ~1s reconcile
  // reflects it (mount-from-response). { sessionId -> partial tab override }.
  const [pending, setPending] = useState<Record<string, Partial<SessionTab>>>({});
  const [connectError, setConnectError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // The "+" button's rect while the variant picker is open (null = closed).
  const [menuAnchor, setMenuAnchor] = useState<DOMRect | null>(null);

  const storeTabs: SessionTab[] = session?.tabs ?? [];

  // The tab list: the server projection, with local optimism merged over it.
  const tabs: SessionTab[] = (() => {
    const byId = new Map<string, SessionTab>(storeTabs.map((t) => [t.sessionId, { ...t }]));
    for (const [sid, ov] of Object.entries(pending)) {
      const ex = byId.get(sid);
      if (ex) byId.set(sid, { ...ex, ...ov });
      else
        byId.set(sid, {
          sessionId: sid,
          name: "claude",
          createdAt: new Date().toISOString(),
          kind: "claude-code",
          connected: true,
          lock: null,
          ...ov,
        });
    }
    return [...byId.values()];
  })();

  // Reset node-level edit buffers when the selected workstream changes.
  useEffect(() => {
    if (session) {
      setEditName(session.customName || session.agentName);
      setEditNotes(session.notes || "");
      setEditColor(session.customColor || session.color);
      const nodeIcon = node?.data?.icon;
      setEditIcon(typeof nodeIcon === "string" ? nodeIcon : "cpu");
    }
    setIsEditing(false);
    setEditingSessionId(null);
    setConnectError(null);
  }, [selectedNodeId]);

  // Default/clamp the active tab to one that exists.
  useEffect(() => {
    if (tabs.length === 0) {
      if (activeTabId !== undefined) setActiveTabId(undefined);
      return;
    }
    if (!activeTabId || !tabs.some((t) => t.sessionId === activeTabId)) {
      setActiveTabId(tabs[0].sessionId);
    }
  }, [tabs, activeTabId]);

  // Close the rename panel if its session's tab vanished.
  useEffect(() => {
    if (editingSessionId && !tabs.some((t) => t.sessionId === editingSessionId)) {
      setEditingSessionId(null);
    }
  }, [tabs, editingSessionId]);

  // Drop optimism once the reconcile agrees (server truth caught up).
  useEffect(() => {
    setPending((p) => {
      const keys = Object.keys(p);
      if (keys.length === 0) return p;
      let changed = false;
      const next: Record<string, Partial<SessionTab>> = {};
      for (const sid of keys) {
        const t = storeTabs.find((x) => x.sessionId === sid);
        const settled =
          t &&
          (p[sid].connected === undefined || t.connected === p[sid].connected) &&
          (p[sid].name === undefined || t.name === p[sid].name);
        if (settled) changed = true;
        else next[sid] = p[sid];
      }
      return changed ? next : p;
    });
  }, [storeTabs]);

  const activeTab = tabs.find((t) => t.sessionId === activeTabId);

  const handleClose = () => {
    setSidebarOpen(false);
    setSelectedNodeId(null);
    setIsEditing(false);
  };

  const connect = async (tab: SessionTab, force = false) => {
    if (!selectedNodeId) return;
    setBusy(true);
    setConnectError(null);
    setActiveTabId(tab.sessionId);
    try {
      const res = await fetch(`/api/sessions/${selectedNodeId}/sessions/connect`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: tab.sessionId, force }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.status === 409) {
        setConnectError(data.holder ? `In use by ${data.holder}` : data.error || "Locked");
        return;
      }
      if (!res.ok) {
        setConnectError(data.error || "Failed to connect");
        return;
      }
      setPending((p) => ({ ...p, [data.sessionId]: { connected: true } }));
      setActiveTabId(data.sessionId);
    } catch (e: any) {
      setConnectError(e.message);
    } finally {
      setBusy(false);
    }
  };

  // Start a fresh session of `variant` ("claude-code" | "shell") in this workstream.
  const startSession = async (variant: string) => {
    setMenuAnchor(null);
    if (!selectedNodeId) return;
    setBusy(true);
    setConnectError(null);
    try {
      const res = await fetch(`/api/sessions/${selectedNodeId}/sessions`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ variant }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setConnectError(data.error || "Failed to start session");
        return;
      }
      const shell = variant === "shell";
      setPending((p) => ({
        ...p,
        [data.sessionId]: { connected: true, ...(shell ? { name: "shell", kind: "shell" } : {}) },
      }));
      setActiveTabId(data.sessionId);
    } catch (e: any) {
      setConnectError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const disconnect = async (tab: SessionTab) => {
    if (!selectedNodeId) return;
    setPending((p) => {
      const n = { ...p };
      delete n[tab.sessionId];
      return n;
    });
    try {
      await fetch(`/api/sessions/${selectedNodeId}/sessions/${tab.sessionId}/disconnect`, {
        method: "POST",
      });
    } catch {
      // The reconcile loop will reflect the real state.
    }
  };

  const displayColor = editColor || session?.customColor || session?.color || "#888";
  // Workstream-level indicator: checkout problems first, then connection.
  const headerStatus =
    session?.checkoutState === "failed"
      ? { label: "Checkout failed", color: "#EF4444" }
      : session?.checkoutState === "pending"
        ? { label: "Cloning…", color: "#FBBF24" }
        : session?.connected
          ? { label: "Connected", color: "#22C55E" }
          : { label: "Disconnected", color: "#6B7280" };

  return (
    <AnimatePresence>
      {sidebarOpen && session && (
        <motion.div
          initial={{ x: "100%", opacity: 0 }}
          animate={{ x: 0, opacity: 1 }}
          exit={{ x: "100%", opacity: 0 }}
          transition={{ type: "spring", stiffness: 400, damping: 40 }}
          style={{ width }}
          className="fixed right-0 top-14 bottom-0 z-50 flex flex-col bg-canvas-dark border-l border-border"
        >
          {/* Left-edge drag grip: resize the pane by its leftmost edge. */}
          <div
            {...gripProps}
            title="Drag to resize"
            className={`absolute inset-y-0 left-0 w-1.5 -translate-x-1/2 z-10 cursor-col-resize transition-colors ${
              dragging ? "bg-blue-500/60" : "hover:bg-blue-500/50"
            }`}
          />

          {/* Header */}
          <div className="flex-shrink-0 px-4 py-3 border-b border-border">
            <div className="flex items-center gap-3">
              <div
                className="w-3 h-3 rounded-full flex-shrink-0"
                style={{ backgroundColor: displayColor }}
              />
              <div className="flex-1 min-w-0">
                <h2 className="text-sm font-medium text-white truncate">
                  {session.customName || session.agentName}
                </h2>
                <div className="flex items-center gap-2 mt-0.5">
                  <div
                    className="w-1.5 h-1.5 rounded-full flex-shrink-0"
                    style={{ backgroundColor: headerStatus.color }}
                  />
                  <span className="text-[10px] text-zinc-500">{headerStatus.label}</span>
                </div>
              </div>

              <div className="flex items-center gap-1 flex-shrink-0">
                <button
                  onClick={() => setIsEditing(!isEditing)}
                  className={`w-7 h-7 rounded flex items-center justify-center transition-colors ${
                    isEditing
                      ? "text-white bg-surface-active"
                      : "text-zinc-500 hover:text-white hover:bg-surface-active"
                  }`}
                >
                  <Edit3 className="w-4 h-4" />
                </button>
                <button
                  onClick={handleClose}
                  className="w-7 h-7 rounded flex items-center justify-center text-zinc-500 hover:text-white hover:bg-surface-active transition-colors"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>

          {/* Edit Panel */}
          <AnimatePresence>
            {isEditing && (
              <motion.div
                initial={{ height: 0, opacity: 0 }}
                animate={{ height: "auto", opacity: 1 }}
                exit={{ height: 0, opacity: 0 }}
                className="flex-shrink-0 overflow-hidden border-b border-border"
              >
                <div className="p-4 space-y-4">
                  <div>
                    <label className="text-[10px] text-zinc-500 uppercase tracking-wider">Name</label>
                    <input
                      type="text"
                      value={editName}
                      onChange={(e) => {
                        const newName = e.target.value;
                        setEditName(newName);
                        if (selectedNodeId && session) {
                          const customName = newName !== session.agentName ? newName : undefined;
                          updateSession(selectedNodeId, { customName });
                          if (node) {
                            updateNode(selectedNodeId, {
                              data: { ...node.data, label: newName },
                            });
                          }
                          fetch(`/api/sessions/${selectedNodeId}`, {
                            method: "PATCH",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ customName }),
                          }).catch(console.error);
                        }
                      }}
                      className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm focus:outline-none focus:border-zinc-500 transition-colors"
                    />
                  </div>

                  <div>
                    <label className="text-[10px] text-zinc-500 uppercase tracking-wider">Color</label>
                    <div className="mt-2 flex flex-wrap gap-2">
                      {presetColors.map((color) => (
                        <button
                          key={color}
                          onClick={() => {
                            setEditColor(color);
                            if (selectedNodeId && session) {
                              updateSession(selectedNodeId, { customColor: color });
                              if (node) {
                                updateNode(selectedNodeId, {
                                  data: { ...node.data, color },
                                });
                              }
                              fetch(`/api/sessions/${selectedNodeId}`, {
                                method: "PATCH",
                                headers: { "Content-Type": "application/json" },
                                body: JSON.stringify({ customColor: color }),
                              }).catch(console.error);
                            }
                          }}
                          className={`w-7 h-7 rounded-md transition-all ${
                            editColor === color
                              ? "ring-2 ring-white ring-offset-2 ring-offset-canvas-dark scale-110"
                              : "hover:scale-110"
                          }`}
                          style={{ backgroundColor: color }}
                        />
                      ))}
                    </div>
                  </div>

                  <div>
                    <label className="text-[10px] text-zinc-500 uppercase tracking-wider">Icon</label>
                    <div className="mt-2 flex flex-wrap gap-2">
                      {iconOptions.map(({ id, icon: IconComponent }) => (
                        <button
                          key={id}
                          onClick={() => {
                            setEditIcon(id);
                            if (selectedNodeId && node) {
                              updateNode(selectedNodeId, {
                                data: { ...node.data, icon: id },
                              });
                            }
                          }}
                          className={`w-9 h-9 rounded-md transition-all flex items-center justify-center ${
                            editIcon === id
                              ? "ring-2 ring-white ring-offset-2 ring-offset-canvas-dark scale-110 bg-white/10"
                              : "hover:scale-110 hover:bg-white/5 bg-canvas"
                          }`}
                          style={{ borderColor: editIcon === id ? editColor : "#333", borderWidth: "1px" }}
                        >
                          <IconComponent
                            className="w-4 h-4"
                            style={{ color: editIcon === id ? editColor : "#888" }}
                          />
                        </button>
                      ))}
                    </div>
                  </div>

                  <div>
                    <label className="text-[10px] text-zinc-500 uppercase tracking-wider">Notes</label>
                    <textarea
                      value={editNotes}
                      onChange={(e) => setEditNotes(e.target.value)}
                      onBlur={() => {
                        if (selectedNodeId && session) {
                          fetch(`/api/sessions/${selectedNodeId}`, {
                            method: "PATCH",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ notes: editNotes || undefined }),
                          }).catch(console.error);
                          updateSession(selectedNodeId, { notes: editNotes || undefined });
                        }
                      }}
                      placeholder="Add notes..."
                      rows={2}
                      className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm placeholder-zinc-600 focus:outline-none focus:border-zinc-500 transition-colors resize-none"
                    />
                  </div>
                </div>
              </motion.div>
            )}
          </AnimatePresence>

          {/* Session tabs */}
          <div className="flex-shrink-0 flex items-stretch gap-1 px-2 pt-2 border-b border-border overflow-x-auto">
            {tabs.map((t) => {
              const lockedByOther = t.lock && !t.lock.mine;
              const dot = t.connected ? "#22C55E" : lockedByOther ? "#FBBF24" : "#6B7280";
              const isActive = t.sessionId === activeTabId;
              const isEditingTab = editingSessionId === t.sessionId;
              return (
                <div
                  key={t.sessionId}
                  className={`flex items-center gap-1.5 pl-3 pr-1.5 py-1.5 rounded-t-md text-xs whitespace-nowrap transition-colors ${
                    isActive
                      ? "bg-[#0d0d0d] text-white border-b-2 border-white"
                      : "text-zinc-400 hover:bg-surface-active"
                  }`}
                >
                  <button
                    onClick={() => {
                      // Switching to a different tab closes an open rename pane.
                      if (t.sessionId !== activeTabId) setEditingSessionId(null);
                      setActiveTabId(t.sessionId);
                    }}
                    title={t.sessionId}
                    className={`flex items-center gap-1.5 min-w-0 ${isActive ? "" : "hover:text-white"}`}
                  >
                    <span className="w-1.5 h-1.5 rounded-full flex-shrink-0" style={{ backgroundColor: dot }} />
                    <span className="max-w-[120px] truncate">{tabLabel(t)}</span>
                  </button>
                  {lockedByOther && <Lock className="w-3 h-3 text-amber-400 flex-shrink-0" />}
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      setActiveTabId(t.sessionId);
                      if (isEditingTab) {
                        setEditingSessionId(null);
                      } else {
                        setEditingSessionId(t.sessionId);
                        setEditSessionName(t.name);
                      }
                    }}
                    title="Rename session"
                    className={`flex-shrink-0 rounded p-0.5 transition-colors ${
                      isEditingTab
                        ? "text-white bg-surface-active"
                        : "text-zinc-600 hover:text-white"
                    }`}
                  >
                    <Edit3 className="w-3 h-3" />
                  </button>
                </div>
              );
            })}
            <button
              onClick={(e) => setMenuAnchor(e.currentTarget.getBoundingClientRect())}
              disabled={busy}
              title="Start a new session"
              className="flex items-center justify-center px-2 py-1.5 rounded-t-md text-zinc-400 hover:text-white hover:bg-surface-active transition-colors disabled:opacity-50"
            >
              <Plus className="w-3.5 h-3.5" />
            </button>
          </div>

          {/* Session rename panel (expands under the tab whose pencil was clicked) */}
          <AnimatePresence>
            {editingSessionId && (
              <motion.div
                initial={{ height: 0, opacity: 0 }}
                animate={{ height: "auto", opacity: 1 }}
                exit={{ height: 0, opacity: 0 }}
                className="flex-shrink-0 overflow-hidden border-b border-border"
              >
                <div className="p-4">
                  <label className="text-[10px] text-zinc-500 uppercase tracking-wider">
                    Session title
                  </label>
                  <input
                    type="text"
                    autoFocus
                    value={editSessionName}
                    onChange={(e) => {
                      const sid = editingSessionId;
                      if (!sid) return;
                      const v = e.target.value;
                      setEditSessionName(v);
                      setPending((p) => ({ ...p, [sid]: { ...p[sid], name: v } }));
                      if (selectedNodeId && v.trim()) {
                        fetch(`/api/sessions/${selectedNodeId}/sessions/${sid}`, {
                          method: "PATCH",
                          headers: { "Content-Type": "application/json" },
                          body: JSON.stringify({ name: v }),
                        }).catch(console.error);
                      }
                    }}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" || e.key === "Escape") setEditingSessionId(null);
                    }}
                    className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm focus:outline-none focus:border-zinc-500 transition-colors"
                  />
                </div>
              </motion.div>
            )}
          </AnimatePresence>

          {/* Active session pane */}
          <div className="flex-1 flex flex-col min-h-0">
            {!activeTab ? (
              <div className="flex-1 flex items-center justify-center p-6 text-center">
                <div>
                  <p className="text-sm text-zinc-400">No sessions yet</p>
                  <button
                    onClick={(e) => setMenuAnchor(e.currentTarget.getBoundingClientRect())}
                    disabled={busy}
                    className="mt-3 inline-flex items-center gap-2 px-3 py-1.5 rounded-md bg-white text-canvas text-sm font-medium hover:bg-zinc-100 disabled:opacity-50 transition-colors"
                  >
                    {busy ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Plus className="w-3.5 h-3.5" />}
                    Start a session
                  </button>
                </div>
              </div>
            ) : activeTab.connected ? (
              <>
                <div className="flex-shrink-0 px-4 py-2 border-b border-border flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <TerminalIcon className="w-3.5 h-3.5 text-zinc-500" />
                    <span className="text-xs text-zinc-500">Terminal</span>
                  </div>
                  <button
                    onClick={() => disconnect(activeTab)}
                    title="Disconnect (keeps the session)"
                    className="flex items-center gap-1.5 px-2 py-1 rounded text-[11px] text-zinc-400 hover:text-white hover:bg-surface-active transition-colors"
                  >
                    <Power className="w-3 h-3" />
                    Disconnect
                  </button>
                </div>
                <div className="flex-1 min-h-0 bg-[#0d0d0d]">
                  <Terminal
                    key={activeTab.sessionId}
                    sessionId={activeTab.sessionId}
                    color={displayColor}
                  />
                </div>
              </>
            ) : (
              <div className="flex-1 flex items-center justify-center p-6">
                <div className="w-full max-w-sm space-y-3 text-center">
                  <Plug className="w-6 h-6 text-zinc-500 mx-auto" />
                  <div>
                    <p className="text-sm text-white font-medium">{tabLabel(activeTab)}</p>
                    <p className="text-xs text-zinc-500 mt-0.5">
                      Disconnected — connecting resumes this Claude Code conversation.
                    </p>
                  </div>
                  {activeTab.lock && !activeTab.lock.mine ? (
                    <div className="space-y-2">
                      <div className="flex items-center justify-center gap-1.5 text-xs text-amber-400">
                        <Lock className="w-3.5 h-3.5" />
                        In use by {activeTab.lock.holder}
                      </div>
                      <button
                        onClick={() => connect(activeTab, true)}
                        disabled={busy}
                        className="w-full flex items-center justify-center gap-2 px-3 py-1.5 rounded-md bg-amber-500 text-black text-sm font-medium hover:bg-amber-400 disabled:opacity-50 transition-colors"
                      >
                        {busy ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Power className="w-3.5 h-3.5" />}
                        Force connect
                      </button>
                    </div>
                  ) : (
                    <button
                      onClick={() => connect(activeTab)}
                      disabled={busy}
                      className="w-full flex items-center justify-center gap-2 px-3 py-1.5 rounded-md bg-white text-canvas text-sm font-medium hover:bg-zinc-100 disabled:opacity-50 transition-colors"
                    >
                      {busy ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Plug className="w-3.5 h-3.5" />}
                      Connect
                    </button>
                  )}
                  {connectError && <p className="text-xs text-red-400">{connectError}</p>}
                </div>
              </div>
            )}
          </div>

          {/* Details */}
          <div className="flex-shrink-0 border-t border-border">
            <div className="p-4 space-y-2">
              {session.notes && !isEditing && (
                <p className="text-xs text-zinc-400 italic mb-3 pb-3 border-b border-border">
                  {session.notes}
                </p>
              )}
              <div className="flex items-center gap-2 text-xs">
                <Clock className="w-3 h-3 text-zinc-600 flex-shrink-0" />
                <span className="text-zinc-500">Started</span>
                <span className="text-zinc-400 font-mono ml-auto">
                  {new Date(session.createdAt).toLocaleTimeString()}
                </span>
              </div>
              <div className="flex items-center gap-2 text-xs">
                <Folder className="w-3 h-3 text-zinc-600 flex-shrink-0" />
                <span className="text-zinc-500">Directory</span>
                <span className="text-zinc-400 font-mono ml-auto truncate max-w-[180px]" title={session.cwd}>
                  {session.cwd.split("/").slice(-2).join("/")}
                </span>
              </div>
              {session.gitBranch && (
                <div className="flex items-center gap-2 text-xs">
                  <GitBranch className="w-3 h-3 text-zinc-600 flex-shrink-0" />
                  <span className="text-zinc-500">Branch</span>
                  <span className="text-purple-400 font-mono ml-auto">{session.gitBranch}</span>
                </div>
              )}
            </div>
          </div>

          <NewSessionMenu
            open={menuAnchor !== null}
            anchor={menuAnchor}
            agents={agents}
            onClose={() => setMenuAnchor(null)}
            onPick={startSession}
          />
        </motion.div>
      )}
    </AnimatePresence>
  );
}
