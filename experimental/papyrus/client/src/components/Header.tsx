import { useState } from "react";
import { Plus, Folder, Monitor, Sun, Moon } from "lucide-react";
import { motion } from "framer-motion";
import { useStore } from "../stores/useStore";
import { ThemeMenu } from "./ThemeMenu";

export function Header() {
  const { setAddAgentModalOpen, sessions, launchCwd, themePreference, setThemePreference } =
    useStore();
  // The theme button's rect while its menu is open (null = closed).
  const [themeAnchor, setThemeAnchor] = useState<DOMRect | null>(null);

  // Icon reflects the current preference: an explicit theme shows its face, follow-system
  // shows the monitor.
  const ThemeIcon =
    themePreference.mode === "fixed"
      ? themePreference.theme === "light"
        ? Sun
        : Moon
      : Monitor;

  return (
    <header className="h-14 px-4 flex items-center justify-between border-b border-border bg-canvas-dark">
      {/* Logo */}
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-2">
          <div className="w-6 h-6 rounded-md bg-gradient-to-br from-violet-500 to-orange-500 flex items-center justify-center">
            <div className="w-2 h-2 rounded-full bg-white" />
          </div>
          <span className="text-sm font-semibold text-content">papyrus</span>
        </div>

        <div className="h-4 w-px bg-border mx-2" />

        <div className="flex items-center gap-1.5 text-xs text-content-subtle">
          <Folder className="w-3 h-3" />
          <span className="font-mono truncate max-w-[200px]">{launchCwd || "~"}</span>
        </div>
      </div>

      {/* Center - node count */}
      <div className="absolute left-1/2 -translate-x-1/2">
        <div className="flex items-center gap-2 px-3 py-1 rounded-full bg-surface text-xs text-content-muted">
          <div className={`w-1.5 h-1.5 rounded-full ${sessions.size > 0 ? "bg-green-500" : "bg-zinc-600"}`} />
          <span>
            {sessions.size} workstream{sessions.size !== 1 ? "s" : ""}
          </span>
        </div>
      </div>

      {/* Right side */}
      <div className="flex items-center gap-2">
        <button
          onClick={(e) => setThemeAnchor(e.currentTarget.getBoundingClientRect())}
          title="Theme"
          aria-label="Theme"
          className="flex items-center justify-center px-2 py-1.5 rounded-md text-content-faint hover:text-content hover:bg-surface-active transition-colors"
        >
          <ThemeIcon className="w-4 h-4" />
        </button>

        <motion.button
          onClick={() => setAddAgentModalOpen(true)}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-inverse text-inverse-content text-sm font-medium hover:bg-inverse/90 transition-colors"
          whileHover={{ scale: 1.02 }}
          whileTap={{ scale: 0.98 }}
        >
          <Plus className="w-4 h-4" />
          New Workstream
        </motion.button>
      </div>

      <ThemeMenu
        open={themeAnchor !== null}
        anchor={themeAnchor}
        preference={themePreference}
        onPick={setThemePreference}
        onClose={() => setThemeAnchor(null)}
      />
    </header>
  );
}
