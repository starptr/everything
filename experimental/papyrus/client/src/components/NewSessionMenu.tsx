import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import {
  Terminal,
  Sparkles,
  Code,
  Cpu,
  Zap,
  Rocket,
  Bot,
  Brain,
  Wand2,
} from "lucide-react";
import {
  FALLBACK_SESSION_SCHEMA,
  schemaToRows,
  type SessionKindInfo,
} from "./sessionSchema";

// Icon-string → component, matching the canvas node's map (AgentNode/index.tsx).
const iconMap: Record<string, any> = {
  sparkles: Sparkles,
  code: Code,
  cpu: Cpu,
  zap: Zap,
  rocket: Rocket,
  bot: Bot,
  brain: Brain,
  wand2: Wand2,
  terminal: Terminal,
};

// What a picked row creates: the silverwood kind tag + its option values (POSTed verbatim).
export interface SessionPick {
  kind: string;
  options: Record<string, string>;
}

interface NewSessionMenuProps {
  open: boolean;
  anchor: DOMRect | null;
  onClose: () => void;
  onPick: (pick: SessionPick) => void;
}

const MENU_WIDTH = 244;

// An anchored dropdown that opens under the "+" button, letting the user pick the session
// to start. Rows are generated from `silverwood session-schema` (GET /api/session-schema)
// so the kind list lives only in silverwood — a required bool option (e.g. run-direnv-exec)
// becomes two rows. Rendered in a body portal so it escapes the sidebar's overflow; closes
// on outside-click or Escape.
export function NewSessionMenu({ open, anchor, onClose, onPick }: NewSessionMenuProps) {
  const [schema, setSchema] = useState<SessionKindInfo[]>(FALLBACK_SESSION_SCHEMA);

  useEffect(() => {
    if (!open) return;
    // Refresh from silverwood each open (cheap); keep the fallback if it fails.
    fetch("/api/session-schema")
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (Array.isArray(data)) setSchema(data);
      })
      .catch(() => {});
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest(".new-session-menu")) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    // Defer the click listener a tick so the opening click doesn't close it.
    const t = setTimeout(() => window.addEventListener("click", onClick), 0);
    window.addEventListener("keydown", onKey);
    return () => {
      clearTimeout(t);
      window.removeEventListener("click", onClick);
      window.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);

  const rows = useMemo(() => schemaToRows(schema), [schema]);

  if (!open || !anchor) return null;

  const left = Math.max(8, Math.min(anchor.left, window.innerWidth - MENU_WIDTH - 8));
  const top = anchor.bottom + 4;

  return createPortal(
    <div
      className="new-session-menu fixed z-[9999] rounded-lg border border-popover-border bg-popover shadow-xl py-1"
      style={{ left, top, width: MENU_WIDTH }}
    >
      {rows.map((row) => {
        const Icon = iconMap[row.icon] || Cpu;
        return (
          <button
            key={row.key}
            disabled={row.disabled}
            onClick={() => {
              if (row.disabled) return;
              onPick({ kind: row.kind, options: row.options });
              onClose();
            }}
            className={`w-full px-3 py-2 text-left flex items-start gap-2.5 transition-colors ${
              row.disabled ? "opacity-40 cursor-not-allowed" : "hover:bg-surface-active"
            }`}
          >
            <Icon
              className="w-4 h-4 flex-shrink-0 mt-0.5"
              style={{ color: row.color || "rgb(var(--color-content-muted))" }}
            />
            <div className="min-w-0">
              <div className="text-xs text-content break-words">{row.label}</div>
              <div className="text-[10px] text-content-subtle whitespace-normal break-words">
                {row.description}
              </div>
            </div>
          </button>
        );
      })}
    </div>,
    document.body,
  );
}
