import { createPortal } from "react-dom";
import { Archive } from "lucide-react";

interface AgentNodeContextMenuProps {
  position: { x: number; y: number };
  onClose: () => void;
  onArchive: () => void;
}

export function AgentNodeContextMenu({
  position,
  onClose,
  onArchive,
}: AgentNodeContextMenuProps) {
  return createPortal(
    <div
      className="context-menu-container fixed z-[9999] min-w-[160px] rounded-lg border shadow-xl py-1"
      style={{
        left: position.x,
        top: position.y,
        backgroundColor: "#262626",
        borderColor: "#333",
      }}
    >
      <button
        onClick={() => {
          onArchive();
          onClose();
        }}
        className="w-full px-3 py-2 text-left text-xs text-yellow-400 hover:bg-white/5 flex items-center gap-2"
      >
        <Archive className="w-3.5 h-3.5" />
        Archive
      </button>
    </div>,
    document.body
  );
}
