import { AnimatePresence, motion } from "framer-motion";
import { X, Minus, Plus, TerminalSquare, Ghost, type LucideIcon } from "lucide-react";
import { useStore } from "../stores/useStore";
import {
  LINE_SPACING_STEP,
  MIN_LINE_SPACING,
  MAX_LINE_SPACING,
  TERMINAL_BACKENDS,
  type BackendId,
} from "../settings";

const BACKEND_ICON: Record<BackendId, LucideIcon> = {
  xterm: TerminalSquare,
  ghostty: Ghost,
};

// Global appearance settings, docked to the right edge and toggled by the header gear.
// Mirrors Sidebar's slide-in; sits above it (z-[60]) so the two never collide. Holds the
// emulator backend selector, then a section of options for the selected emulator only —
// line spacing (stepper) under xterm; ghostty has none yet. The store persists both fields.
export function SettingsPanel() {
  const settingsOpen = useStore((s) => s.settingsOpen);
  const setSettingsOpen = useStore((s) => s.setSettingsOpen);
  const terminalBackend = useStore((s) => s.terminalBackend);
  const setTerminalBackend = useStore((s) => s.setTerminalBackend);
  const lineSpacing = useStore((s) => s.lineSpacing);
  const setLineSpacing = useStore((s) => s.setLineSpacing);

  const atMin = lineSpacing <= MIN_LINE_SPACING;
  const atMax = lineSpacing >= MAX_LINE_SPACING;
  const activeBackendLabel =
    TERMINAL_BACKENDS.find((b) => b.id === terminalBackend)?.label ?? terminalBackend;

  return (
    <AnimatePresence>
      {settingsOpen && (
        <motion.div
          initial={{ x: "100%", opacity: 0 }}
          animate={{ x: 0, opacity: 1 }}
          exit={{ x: "100%", opacity: 0 }}
          transition={{ type: "spring", stiffness: 400, damping: 40 }}
          className="fixed right-0 top-14 bottom-0 z-[60] w-72 flex flex-col bg-canvas-dark border-l border-border"
        >
          {/* Header */}
          <div className="flex-shrink-0 px-4 py-3 border-b border-border flex items-center justify-between">
            <h2 className="text-sm font-medium text-content">Settings</h2>
            <button
              onClick={() => setSettingsOpen(false)}
              aria-label="Close settings"
              className="w-7 h-7 rounded flex items-center justify-center text-content-subtle hover:text-content hover:bg-surface-active transition-colors"
            >
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Body */}
          <div className="flex-1 overflow-y-auto p-4 space-y-4">
            <div>
              <label className="text-[10px] text-content-subtle uppercase tracking-wider">
                Terminal
              </label>
              <div className="mt-2">
                <span className="text-sm text-content">Emulator</span>
                <div className="mt-1.5 flex flex-col gap-1 rounded-md bg-canvas border border-border p-0.5">
                  {TERMINAL_BACKENDS.map(({ id, label }) => {
                    const Icon = BACKEND_ICON[id];
                    const active = terminalBackend === id;
                    return (
                      <button
                        key={id}
                        onClick={() => setTerminalBackend(id)}
                        aria-pressed={active}
                        aria-label={`Use ${label}`}
                        className={`flex items-center gap-2 w-full px-2 py-1.5 rounded transition-colors ${
                          active
                            ? "text-content bg-surface-active"
                            : "text-content-subtle hover:text-content hover:bg-surface-active"
                        }`}
                      >
                        <Icon className="w-3.5 h-3.5" />
                        <span className="text-sm">{label}</span>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Options specific to the selected emulator */}
            <div>
              <label className="text-[10px] text-content-subtle uppercase tracking-wider">
                {activeBackendLabel} options
              </label>

              {terminalBackend === "xterm" && (
                <div className="mt-2 flex items-center justify-between">
                  <span className="text-sm text-content">Line spacing</span>
                  <div className="flex items-center gap-1 rounded-md bg-canvas border border-border p-0.5">
                    <button
                      onClick={() => setLineSpacing(lineSpacing - LINE_SPACING_STEP)}
                      disabled={atMin}
                      aria-label="Decrease line spacing"
                      className={`w-6 h-6 rounded flex items-center justify-center transition-colors ${
                        atMin
                          ? "text-content-faint opacity-40 cursor-not-allowed"
                          : "text-content-subtle hover:text-content hover:bg-surface-active"
                      }`}
                    >
                      <Minus className="w-3.5 h-3.5" />
                    </button>
                    <span className="w-10 text-center font-mono text-sm text-content tabular-nums">
                      {lineSpacing.toFixed(2)}
                    </span>
                    <button
                      onClick={() => setLineSpacing(lineSpacing + LINE_SPACING_STEP)}
                      disabled={atMax}
                      aria-label="Increase line spacing"
                      className={`w-6 h-6 rounded flex items-center justify-center transition-colors ${
                        atMax
                          ? "text-content-faint opacity-40 cursor-not-allowed"
                          : "text-content-subtle hover:text-content hover:bg-surface-active"
                      }`}
                    >
                      <Plus className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              )}

              {terminalBackend === "ghostty" && (
                <p className="mt-2 text-sm text-content-subtle">No settings for libghostty yet.</p>
              )}
            </div>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
