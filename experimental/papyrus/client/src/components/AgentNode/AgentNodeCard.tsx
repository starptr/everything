import { GitBranch, Folder } from "lucide-react";
import { AgentIcon } from "../AgentIcon";

// A single node indicator folding connection + checkout state (no live agent
// activity — that needed the plugin hook). Precedence: checkout problems first,
// then whether a session is connected in this papyrus instance.
function nodeIndicator(
  connected: boolean,
  checkoutState?: string,
): { label: string; color: string } {
  if (checkoutState === "failed") return { label: "Checkout failed", color: "#EF4444" };
  if (checkoutState === "pending") return { label: "Cloning…", color: "#FBBF24" };
  if (connected) return { label: "Connected", color: "#22C55E" };
  return { label: "Disconnected", color: "#6B7280" };
}

interface AgentNodeCardProps {
  selected: boolean;
  displayColor: string;
  displayName: string;
  icon: string;
  agentId: string;
  connected: boolean;
  checkoutState?: string;
  cwd?: string;
  originalCwd?: string; // Mother repo path when using worktrees
  gitBranch?: string;
  ticketId?: string;
  ticketTitle?: string;
}

export function AgentNodeCard({
  selected,
  displayColor,
  displayName,
  icon,
  agentId,
  connected,
  checkoutState,
  cwd,
  originalCwd,
  gitBranch,
  ticketId,
  ticketTitle,
}: AgentNodeCardProps) {
  // agentId is available for future use if needed
  void agentId;
  const indicator = nodeIndicator(connected, checkoutState);

  // Extract directory name - use originalCwd (mother repo) if available, otherwise cwd
  const displayCwd = originalCwd || cwd;
  const dirName = displayCwd ? displayCwd.split("/").pop() || displayCwd : null;

  return (
    <div
      className={`relative w-[220px] rounded-lg transition-all duration-300 cursor-pointer ${
        selected ? "ring-1 ring-content/20" : ""
      }`}
      style={{
        backgroundColor: "rgb(var(--color-surface))",
        border: connected ? `1px solid ${indicator.color}40` : "1px solid rgb(var(--color-border))",
        boxShadow: selected
          ? "0 8px 24px rgba(0, 0, 0, 0.6)"
          : "0 4px 12px rgba(0, 0, 0, 0.4)",
      }}
    >
      {/* Top edge: the workstream's connection-status color */}
      <div className="h-1 rounded-t-lg" style={{ backgroundColor: indicator.color }} />

      {/* Indicator banner: connection + checkout */}
      <div className="px-3 py-1.5 flex items-center gap-2">
        <div className="w-2 h-2 rounded-full" style={{ backgroundColor: indicator.color }} />
        <span className="text-xs font-medium" style={{ color: indicator.color }}>
          {indicator.label}
        </span>
      </div>

      <div className="p-3 relative">
        {/* Agent name and icon */}
        <div className="flex items-center gap-2.5">
          <AgentIcon icon={icon} color={displayColor} />
          <div className="min-w-0 flex-1">
            <h3 className="text-sm font-semibold text-content truncate leading-tight">{displayName}</h3>
            <p className="text-[10px] text-content-subtle">{agentId}</p>
          </div>
        </div>

        {/* Ticket info */}
        {ticketId && (
          <div className="mt-2.5 px-2 py-1.5 rounded-md bg-indigo-500/10 border border-indigo-500/20">
            <div className="flex items-center gap-1.5">
              <span className="text-[10px] font-mono font-semibold text-indigo-400">{ticketId}</span>
            </div>
            {ticketTitle && (
              <p className="text-[10px] text-indigo-300/70 truncate mt-0.5">{ticketTitle}</p>
            )}
          </div>
        )}

        {/* Repo & Branch */}
        {(dirName || gitBranch) && (
          <div className="mt-2 space-y-1">
            {dirName && (
              <div className="flex items-center gap-1.5">
                <Folder className="w-3.5 h-3.5 text-content-subtle flex-shrink-0" />
                <span className="text-[11px] text-content-muted font-mono truncate">{dirName}</span>
              </div>
            )}
            {gitBranch && (
              <div className="flex items-center gap-1.5">
                <GitBranch className="w-3.5 h-3.5 text-purple-400 flex-shrink-0" />
                <span className="text-[11px] text-purple-400 font-mono truncate">{gitBranch}</span>
              </div>
            )}
          </div>
        )}

      </div>
    </div>
  );
}
