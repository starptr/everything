import { useState, useEffect, useRef, useCallback } from "react";
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
  Trash2,
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
import { AgentIcon } from "./AgentIcon";
import { type PendingOptimism, shouldDropOptimism, mergePendingTabs } from "./sessionOptimism";
import { Terminal } from "./Terminal";
import { NewSessionMenu } from "./NewSessionMenu";
import { useResizablePane } from "./useResizablePane";
import { workstreamStateLabel } from "../workstreamState";

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
  // reflects it (mount-from-response). Each override is stamped with the reconcile
  // generation it was set at (so a `connected` optimism can be retired even if the
  // server never echoes it — the fast-fail race). **Scoped per workstream** (node id
  // → sessionId → override): an override only applies to the workstream it was made
  // in, so switching workstreams can never surface a phantom tab in another one.
  const [pendingByNode, setPendingByNode] = useState<
    Record<string, Record<string, PendingOptimism>>
  >({});
  const pending = selectedNodeId ? (pendingByNode[selectedNodeId] ?? {}) : {};
  // Update the selected workstream's optimism bucket (no-op with nothing selected).
  // Keeps the historic `setPending((prev) => next)` shape at every call site.
  const setPending = useCallback(
    (
      updater: (
        prev: Record<string, PendingOptimism>,
      ) => Record<string, PendingOptimism>,
    ) => {
      if (!selectedNodeId) return;
      setPendingByNode((byNode) => ({
        ...byNode,
        [selectedNodeId]: updater(byNode[selectedNodeId] ?? {}),
      }));
    },
    [selectedNodeId],
  );
  const reconcileSeqRef = useRef(0);
  const [connectError, setConnectError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // The "+" button's rect while the variant picker is open (null = closed).
  const [menuAnchor, setMenuAnchor] = useState<DOMRect | null>(null);

  const storeTabs: SessionTab[] = session?.tabs ?? [];

  // The tab list: the server projection, with THIS workstream's optimism merged over
  // it (`pending` is already scoped to the selected node — see `pendingByNode`).
  const tabs: SessionTab[] = mergePendingTabs(storeTabs, pending);

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

  // Each reconcile bumps the generation counter; drop optimism once the server agrees, or
  // (for a `connected` optimism) once ≥2 reconciles have elapsed since it was set — so a
  // resume that fails before the server ever reports `connected:true` still unsticks the tab.
  useEffect(() => {
    reconcileSeqRef.current += 1;
    setPending((p) => {
      const keys = Object.keys(p);
      if (keys.length === 0) return p;
      const seqNow = reconcileSeqRef.current;
      let changed = false;
      const next: Record<string, PendingOptimism> = {};
      for (const sid of keys) {
        const t = storeTabs.find((x) => x.sessionId === sid);
        if (shouldDropOptimism(p[sid], t, seqNow)) changed = true;
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
      setPending((p) => ({
        ...p,
        [data.sessionId]: { ov: { connected: true }, seq: reconcileSeqRef.current },
      }));
      setActiveTabId(data.sessionId);
    } catch (e: any) {
      setConnectError(e.message);
    } finally {
      setBusy(false);
    }
  };

  // Start a fresh session of `variant` ("claude-code" | "plain-shell") in this workstream.
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
      const shell = variant === "plain-shell";
      setPending((p) => ({
        ...p,
        [data.sessionId]: {
          ov: { connected: true, ...(shell ? { name: "shell", kind: "plain-shell" } : {}) },
          seq: reconcileSeqRef.current,
        },
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

  // Remove a session for good: kill any live PTY and delete its silverwood record.
  // This is how a plain shell is closed (doctor can't retire a conversation-less
  // shell). The tab vanishes on the next reconcile; drop its optimism now.
  const removeSession = async (tab: SessionTab) => {
    if (!selectedNodeId) return;
    setPending((p) => {
      const n = { ...p };
      delete n[tab.sessionId];
      return n;
    });
    if (editingSessionId === tab.sessionId) setEditingSessionId(null);
    try {
      await fetch(`/api/sessions/${selectedNodeId}/sessions/${tab.sessionId}`, {
        method: "DELETE",
      });
    } catch {
      // The reconcile loop will reflect the real state.
    }
  };

  const displayColor = editColor || session?.customColor || session?.color || "#888";
  // Workstream-level indicator: silverwood's algebraic state, plus the N/M-connected
  // agent count for a Ready Basic workstream.
  const headerStatus = workstreamStateLabel({
    overallState: session?.overallState,
    kind: session?.kind,
    checkoutState: session?.checkoutState,
    connected: session?.connected ?? false,
    tabs,
  });

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
              <AgentIcon
                icon={editIcon || (node?.data?.icon as string) || "cpu"}
                color={displayColor}
              />
              <div className="flex-1 min-w-0">
                <h2 className="text-sm font-medium text-content truncate">
                  {session.customName || session.agentName}
                </h2>
                <div className="flex items-center gap-2 mt-0.5">
                  <div
                    className="w-1.5 h-1.5 rounded-full flex-shrink-0"
                    style={{ backgroundColor: headerStatus.color }}
                  />
                  <span className="text-[10px] text-content-subtle">{headerStatus.label}</span>
                </div>
              </div>

              <div className="flex items-center gap-1 flex-shrink-0">
                <button
                  onClick={() => setIsEditing(!isEditing)}
                  className={`w-7 h-7 rounded flex items-center justify-center transition-colors ${
                    isEditing
                      ? "text-content bg-surface-active"
                      : "text-content-subtle hover:text-content hover:bg-surface-active"
                  }`}
                >
                  <Edit3 className="w-4 h-4" />
                </button>
                <button
                  onClick={handleClose}
                  className="w-7 h-7 rounded flex items-center justify-center text-content-subtle hover:text-content hover:bg-surface-active transition-colors"
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
                    <label className="text-[10px] text-content-subtle uppercase tracking-wider">Name</label>
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
                      className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-content text-sm focus:outline-none focus:border-border-strong transition-colors"
                    />
                  </div>

                  <div>
                    <label className="text-[10px] text-content-subtle uppercase tracking-wider">Color</label>
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
                              ? "ring-2 ring-content ring-offset-2 ring-offset-canvas-dark scale-110"
                              : "hover:scale-110"
                          }`}
                          style={{ backgroundColor: color }}
                        />
                      ))}
                    </div>
                  </div>

                  <div>
                    <label className="text-[10px] text-content-subtle uppercase tracking-wider">Icon</label>
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
                              ? "ring-2 ring-content ring-offset-2 ring-offset-canvas-dark scale-110 bg-content/10"
                              : "hover:scale-110 hover:bg-content/5 bg-canvas"
                          }`}
                          style={{ borderColor: editIcon === id ? editColor : "rgb(var(--color-border-light))", borderWidth: "1px" }}
                        >
                          <IconComponent
                            className="w-4 h-4"
                            style={{ color: editIcon === id ? editColor : "rgb(var(--color-content-subtle))" }}
                          />
                        </button>
                      ))}
                    </div>
                  </div>

                  <div>
                    <label className="text-[10px] text-content-subtle uppercase tracking-wider">Notes</label>
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
                      className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-content text-sm placeholder-content-faint focus:outline-none focus:border-border-strong transition-colors resize-none"
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
                      ? "bg-canvas text-content border-b-2 border-content"
                      : "text-content-muted hover:bg-surface-active"
                  }`}
                >
                  <button
                    onClick={() => {
                      // Switching to a different tab closes an open rename pane.
                      if (t.sessionId !== activeTabId) setEditingSessionId(null);
                      setActiveTabId(t.sessionId);
                    }}
                    title={t.sessionId}
                    className={`flex items-center gap-1.5 min-w-0 ${isActive ? "" : "hover:text-content"}`}
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
                        ? "text-content bg-surface-active"
                        : "text-content-faint hover:text-content"
                    }`}
                  >
                    <Edit3 className="w-3 h-3" />
                  </button>
                  {/* Close: only plain shells (a shell has no doctor-based removal). */}
                  {t.kind === "plain-shell" && (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        removeSession(t);
                      }}
                      title="Close shell"
                      className="flex-shrink-0 rounded p-0.5 text-content-faint hover:text-content transition-colors"
                    >
                      <X className="w-3 h-3" />
                    </button>
                  )}
                </div>
              );
            })}
            <button
              onClick={(e) => setMenuAnchor(e.currentTarget.getBoundingClientRect())}
              disabled={busy}
              title="Start a new session"
              className="flex items-center justify-center px-2 py-1.5 rounded-t-md text-content-muted hover:text-content hover:bg-surface-active transition-colors disabled:opacity-50"
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
                  <label className="text-[10px] text-content-subtle uppercase tracking-wider">
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
                      setPending((p) => ({
                        ...p,
                        [sid]: { ov: { ...p[sid]?.ov, name: v }, seq: reconcileSeqRef.current },
                      }));
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
                    className="mt-1 w-full px-3 py-2 rounded-md bg-canvas border border-border text-content text-sm focus:outline-none focus:border-border-strong transition-colors"
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
                  <p className="text-sm text-content-muted">No sessions yet</p>
                  <button
                    onClick={(e) => setMenuAnchor(e.currentTarget.getBoundingClientRect())}
                    disabled={busy}
                    className="mt-3 inline-flex items-center gap-2 px-3 py-1.5 rounded-md bg-inverse text-inverse-content text-sm font-medium hover:bg-inverse/90 disabled:opacity-50 transition-colors"
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
                    <TerminalIcon className="w-3.5 h-3.5 text-content-subtle" />
                    <span className="text-xs text-content-subtle">Terminal</span>
                  </div>
                  <button
                    onClick={() => disconnect(activeTab)}
                    title="Disconnect (keeps the session)"
                    className="flex items-center gap-1.5 px-2 py-1 rounded text-[11px] text-content-muted hover:text-content hover:bg-surface-active transition-colors"
                  >
                    <Power className="w-3 h-3" />
                    Disconnect
                  </button>
                </div>
                <div className="flex-1 min-h-0 bg-[rgb(var(--color-terminal-bg))]">
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
                  <Plug className="w-6 h-6 text-content-subtle mx-auto" />
                  <div>
                    <p className="text-sm text-content font-medium">{tabLabel(activeTab)}</p>
                    <p className="text-xs text-content-subtle mt-0.5">
                      {activeTab.kind === "plain-shell"
                        ? "Disconnected — connecting opens a new shell in the checkout."
                        : "Disconnected — connecting resumes this Claude Code conversation (or starts it fresh if none was saved)."}
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
                      className="w-full flex items-center justify-center gap-2 px-3 py-1.5 rounded-md bg-inverse text-inverse-content text-sm font-medium hover:bg-inverse/90 disabled:opacity-50 transition-colors"
                    >
                      {busy ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Plug className="w-3.5 h-3.5" />}
                      Connect
                    </button>
                  )}
                  {activeTab.kind === "plain-shell" && (
                    <button
                      onClick={() => removeSession(activeTab)}
                      disabled={busy}
                      title="Remove this shell (deletes its silverwood record)"
                      className="w-full flex items-center justify-center gap-2 px-3 py-1.5 rounded-md border border-border text-content-muted text-sm font-medium hover:text-content hover:bg-surface-active disabled:opacity-50 transition-colors"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                      Close shell
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
                <p className="text-xs text-content-muted italic mb-3 pb-3 border-b border-border">
                  {session.notes}
                </p>
              )}
              <div className="flex items-center gap-2 text-xs">
                <Clock className="w-3 h-3 text-content-faint flex-shrink-0" />
                <span className="text-content-subtle">Started</span>
                <span className="text-content-muted font-mono ml-auto">
                  {new Date(session.createdAt).toLocaleTimeString()}
                </span>
              </div>
              <div className="flex items-center gap-2 text-xs">
                <Folder className="w-3 h-3 text-content-faint flex-shrink-0" />
                <span className="text-content-subtle">Directory</span>
                <span className="text-content-muted font-mono ml-auto truncate max-w-[180px]" title={session.cwd}>
                  {session.cwd.split("/").slice(-2).join("/")}
                </span>
              </div>
              {session.gitBranch && (
                <div className="flex items-center gap-2 text-xs">
                  <GitBranch className="w-3 h-3 text-content-faint flex-shrink-0" />
                  <span className="text-content-subtle">Branch</span>
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
