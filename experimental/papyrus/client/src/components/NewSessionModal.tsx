import { useState, useEffect } from "react";
import { createPortal } from "react-dom";
import { motion, AnimatePresence } from "framer-motion";
import { X, GitBranch, Loader2, AlertCircle, Sparkles } from "lucide-react";
import { useReactFlow } from "@xyflow/react";
import { useStore, AgentSession } from "../stores/useStore";

interface NewSessionModalProps {
  open: boolean;
  onClose: () => void;
  // When set, we're re-spawning the terminal for an existing workstream node.
  existingSession?: AgentSession;
  existingNodeId?: string;
}

const GRID = 24;

// Create a node = create a silverwood workstream from an https git URL (silverwood
// clones its checkout), then spawn its Claude Code terminal. All durable state
// lives in silverwood; the canvas coordinate is stored in the workstream's KV.
export function NewSessionModal({
  open,
  onClose,
  existingSession,
  existingNodeId,
}: NewSessionModalProps) {
  const { addNode, addSession, updateSession } = useStore();
  const reactFlowInstance = useReactFlow();
  const isReplacing = !!existingNodeId && !!existingSession;

  const [name, setName] = useState("");
  const [source, setSource] = useState("");
  const [isBusy, setIsBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setName("");
      setSource("");
      setError(null);
      setIsBusy(false);
    }
  }, [open]);

  // Place a new node at the current viewport center, snapped to the grid.
  const viewportCenter = () => {
    const vp = reactFlowInstance.getViewport();
    const bounds = document.querySelector(".react-flow")?.getBoundingClientRect();
    const vw = bounds?.width || window.innerWidth;
    const vh = bounds?.height || window.innerHeight;
    return {
      x: Math.round((-vp.x + vw / 2) / vp.zoom / GRID) * GRID,
      y: Math.round((-vp.y + vh / 2) / vp.zoom / GRID) * GRID,
    };
  };

  const handleSpawnFresh = async () => {
    if (!existingNodeId || !existingSession) return;
    setIsBusy(true);
    setError(null);
    try {
      const res = await fetch(`/api/sessions/${existingSession.sessionId}/restart`, {
        method: "POST",
      });
      if (!res.ok) {
        throw new Error((await res.json()).error || "Failed to spawn terminal");
      }
      updateSession(existingNodeId, { status: "running", isRestored: false });
      onClose();
    } catch (e: any) {
      setError(e.message);
    } finally {
      setIsBusy(false);
    }
  };

  const handleCreate = async () => {
    if (!name.trim() || !source.trim()) return;
    setIsBusy(true);
    setError(null);
    try {
      const position = viewportCenter();
      const res = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim(), source: source.trim(), position }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Failed to create workstream");

      const sessionId: string = data.sessionId;
      addNode({
        id: sessionId,
        type: "agent",
        position,
        data: {
          label: name.trim(),
          agentId: "claude",
          color: "#F97316",
          icon: "sparkles",
          sessionId,
        },
      });
      addSession(sessionId, {
        id: sessionId,
        sessionId,
        agentId: "claude",
        agentName: "Claude Code",
        command: "claude",
        color: "#F97316",
        createdAt: new Date().toISOString(),
        cwd: data.cwd || "",
        status: data.checkoutState === "ready" ? "running" : "idle",
        customName: name.trim(),
      });
      onClose();
    } catch (e: any) {
      setError(e.message);
    } finally {
      setIsBusy(false);
    }
  };

  return createPortal(
    <AnimatePresence>
      {open && (
        <>
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={onClose}
            className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm"
          />
          <motion.div
            initial={{ opacity: 0, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.95 }}
            className="fixed inset-0 z-50 flex items-center justify-center pointer-events-none"
          >
            <div className="pointer-events-auto w-full max-w-lg mx-4">
              <div className="rounded-xl bg-surface border border-border shadow-2xl overflow-hidden flex flex-col">
                {/* Header */}
                <div className="px-5 py-4 border-b border-border flex items-center justify-between">
                  <h2 className="text-base font-semibold text-white">
                    {isReplacing ? "Spawn Fresh Terminal" : "New Workstream"}
                  </h2>
                  <button
                    onClick={onClose}
                    className="w-7 h-7 rounded flex items-center justify-center text-zinc-500 hover:text-white hover:bg-surface-active transition-colors"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>

                {/* Body */}
                <div className="p-5 space-y-4">
                  {isReplacing ? (
                    <p className="text-sm text-zinc-400">
                      Spawn a fresh Claude Code terminal in this workstream's checkout.
                      The workstream and its history in silverwood are unchanged.
                    </p>
                  ) : (
                    <>
                      <div className="space-y-2">
                        <label className="text-xs text-zinc-500">Name</label>
                        <input
                          type="text"
                          value={name}
                          onChange={(e) => setName(e.target.value)}
                          placeholder="auth-refactor"
                          autoFocus
                          className="w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm placeholder-zinc-600 focus:outline-none focus:border-zinc-500 transition-colors"
                        />
                      </div>
                      <div className="space-y-2">
                        <label className="text-xs text-zinc-500 flex items-center gap-1.5">
                          <GitBranch className="w-3 h-3" />
                          Source (HTTPS git URL)
                        </label>
                        <input
                          type="text"
                          value={source}
                          onChange={(e) => setSource(e.target.value)}
                          placeholder="https://github.com/owner/repo.git"
                          className="w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm placeholder-zinc-600 focus:outline-none focus:border-zinc-500 transition-colors font-mono"
                        />
                        <p className="text-[10px] text-zinc-600">
                          silverwood clones this into a jj-colocated checkout, then Claude Code
                          runs there. This can take a moment.
                        </p>
                      </div>
                    </>
                  )}

                  {error && (
                    <div className="p-3 rounded-md bg-red-500/10 border border-red-500/20 flex items-start gap-2">
                      <AlertCircle className="w-4 h-4 text-red-500 flex-shrink-0 mt-0.5" />
                      <p className="text-xs text-red-400 break-words">{error}</p>
                    </div>
                  )}
                </div>

                {/* Footer */}
                <div className="px-5 py-3 bg-canvas border-t border-border flex justify-end gap-2">
                  <button
                    onClick={onClose}
                    className="px-3 py-1.5 rounded-md text-sm text-zinc-400 hover:text-white hover:bg-surface-active transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    onClick={isReplacing ? handleSpawnFresh : handleCreate}
                    disabled={isBusy || (!isReplacing && (!name.trim() || !source.trim()))}
                    className="px-4 py-1.5 rounded-md text-sm font-medium text-canvas bg-white hover:bg-zinc-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-1.5"
                  >
                    {isBusy ? (
                      <>
                        <Loader2 className="w-4 h-4 animate-spin" />
                        {isReplacing ? "Spawning..." : "Cloning..."}
                      </>
                    ) : isReplacing ? (
                      "Spawn Fresh"
                    ) : (
                      <>
                        <Sparkles className="w-4 h-4" />
                        Create
                      </>
                    )}
                  </button>
                </div>
              </div>
            </div>
          </motion.div>
        </>
      )}
    </AnimatePresence>,
    document.body,
  );
}
