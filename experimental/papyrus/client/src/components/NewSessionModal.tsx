import { useState, useEffect } from "react";
import { createPortal } from "react-dom";
import { motion, AnimatePresence } from "framer-motion";
import { X, GitBranch, FolderOpen, Loader2, AlertCircle, Sparkles } from "lucide-react";
import { useReactFlow } from "@xyflow/react";
import {
  type CommandNode,
  type Item,
  FALLBACK_SCHEMA,
  defaultDescent,
  nodeAtPath,
  walk,
} from "./newSchema";

interface NewSessionModalProps {
  open: boolean;
  onClose: () => void;
}

const GRID = 24;

// Human label for the choice at each tree depth (cosmetic; the tree, not this list,
// is authoritative — deeper levels fall back to a generic label).
const DEPTH_LABELS = ["Workstream variant", "Checkout mode"];
const depthLabel = (d: number) => DEPTH_LABELS[d] ?? "Option";

// Cosmetic per-positional presentation, keyed on the clap value_name. The functional
// parts (whether the input exists, its help, whether it's required) come from the
// schema, so an unknown value_name still renders a correct, labeled input via the
// humanized fallback.
const SEED_FIELDS: Record<
  string,
  { label: string; placeholder: string; icon: typeof GitBranch }
> = {
  SOURCE_HTTPS_URL: {
    label: "Source (HTTPS git URL)",
    placeholder: "https://github.com/owner/repo.git",
    icon: GitBranch,
  },
  ABSOLUTE_PATH: {
    label: "Absolute path",
    placeholder: "/Users/you/src/project",
    icon: FolderOpen,
  },
};
function fieldConfig(valueName: string) {
  return (
    SEED_FIELDS[valueName] ?? {
      label: valueName
        .replace(/_/g, " ")
        .toLowerCase()
        .replace(/^./, (c) => c.toUpperCase()),
      placeholder: "",
      icon: GitBranch,
    }
  );
}

// Create a node = create a silverwood workstream by walking the `new` command tree:
// pick a path (variant → mode → …), fill its positional args, and POST them. All
// durable state lives in silverwood; the canvas coordinate is stored in the
// workstream's KV. No optimistic node — the ~1s reconcile adds it from the forest.
export function NewSessionModal({ open, onClose }: NewSessionModalProps) {
  const reactFlowInstance = useReactFlow();

  const [name, setName] = useState("");
  const [schema, setSchema] = useState<CommandNode>(FALLBACK_SCHEMA);
  const [path, setPath] = useState<string[]>(() => defaultDescent(FALLBACK_SCHEMA));
  const [argValues, setArgValues] = useState<Record<string, string>>({});
  const [isBusy, setIsBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    const apply = (s: CommandNode) => {
      setSchema(s);
      setPath(defaultDescent(s));
      setArgValues({});
    };
    setName("");
    setError(null);
    setIsBusy(false);
    apply(FALLBACK_SCHEMA);
    fetch("/api/new-schema")
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (data && typeof data.name === "string") apply(data as CommandNode);
      })
      .catch(() => {});
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

  // Choose subcommand `choice` at tree `depth`: truncate the path there, then
  // re-default every deeper level. Typed positionals are cleared — they belonged to
  // the branch we just left.
  const selectAt = (depth: number, choice: string) => {
    const prefix = path.slice(0, depth).concat(choice);
    const chosen = nodeAtPath(schema, prefix);
    setPath(chosen ? prefix.concat(defaultDescent(chosen)) : prefix);
    setArgValues({});
    setError(null);
  };

  const items = walk(schema, path);
  const inputs = items.filter((it): it is Extract<Item, { kind: "input" }> => it.kind === "input");
  const missingRequired = inputs.some(
    ({ key, arg }) => arg.required && !(argValues[key] ?? "").trim(),
  );
  const canCreate = !!name.trim() && !missingRequired && path.length > 0;

  const handleCreate = async () => {
    if (!canCreate) return;
    setIsBusy(true);
    setError(null);
    try {
      const position = viewportCenter();
      const args = inputs.map(({ key }) => (argValues[key] ?? "").trim());
      const res = await fetch("/api/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: name.trim(), path, args, position }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Failed to create workstream");
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
                  <h2 className="text-base font-semibold text-white">New Workstream</h2>
                  <button
                    onClick={onClose}
                    className="w-7 h-7 rounded flex items-center justify-center text-zinc-500 hover:text-white hover:bg-surface-active transition-colors"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>

                {/* Body */}
                <div className="p-5 space-y-4">
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

                  {/* Below Name: a dropdown per tree level, then the chosen leaf's
                      positional inputs — all driven by silverwood's `new` schema. */}
                  {items.map((item) =>
                    item.kind === "select" ? (
                      <div className="space-y-2" key={`sel-${item.depth}`}>
                        <label className="text-xs text-zinc-500">{depthLabel(item.depth)}</label>
                        <select
                          value={item.selected}
                          onChange={(e) => selectAt(item.depth, e.target.value)}
                          className="w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm focus:outline-none focus:border-zinc-500 transition-colors"
                        >
                          {item.node.subcommands.map((s) => (
                            <option key={s.name} value={s.name}>
                              {s.name}
                            </option>
                          ))}
                        </select>
                        <p className="text-[10px] text-zinc-600">
                          {item.node.subcommands.find((s) => s.name === item.selected)?.description}
                        </p>
                      </div>
                    ) : (
                      (() => {
                        const cfg = fieldConfig(item.arg.value_name);
                        const Icon = cfg.icon;
                        return (
                          <div className="space-y-2" key={`arg-${item.key}`}>
                            <label className="text-xs text-zinc-500 flex items-center gap-1.5">
                              <Icon className="w-3 h-3" />
                              {cfg.label}
                            </label>
                            <input
                              type="text"
                              value={argValues[item.key] ?? ""}
                              onChange={(e) =>
                                setArgValues((prev) => ({ ...prev, [item.key]: e.target.value }))
                              }
                              placeholder={cfg.placeholder}
                              className="w-full px-3 py-2 rounded-md bg-canvas border border-border text-white text-sm placeholder-zinc-600 focus:outline-none focus:border-zinc-500 transition-colors font-mono"
                            />
                            {item.arg.help && (
                              <p className="text-[10px] text-zinc-600">{item.arg.help}</p>
                            )}
                          </div>
                        );
                      })()
                    ),
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
                    onClick={handleCreate}
                    disabled={isBusy || !canCreate}
                    className="px-4 py-1.5 rounded-md text-sm font-medium text-canvas bg-white hover:bg-zinc-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-1.5"
                  >
                    {isBusy ? (
                      <>
                        <Loader2 className="w-4 h-4 animate-spin" />
                        Creating…
                      </>
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
