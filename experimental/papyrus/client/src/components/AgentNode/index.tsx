import { NodeProps } from "@xyflow/react";
import { motion } from "framer-motion";
import { useStore } from "../../stores/useStore";
import { AgentNodeCard } from "./AgentNodeCard";
import { AgentNodeContextMenu } from "./AgentNodeContextMenu";
import { useAgentNodeState } from "./useAgentNodeState";

interface AgentNodeData {
  label: string;
  agentId: string;
  color: string;
  icon: string;
  sessionId: string;
}

export const AgentNode = ({ id, data, selected }: NodeProps) => {
  const nodeData = data as unknown as AgentNodeData;

  // Subscribe to the node's connection + checkout state as primitives so the card
  // re-renders when they change.
  const connected = useStore((state) => state.sessions.get(id)?.connected) || false;
  const checkoutState = useStore((state) => state.sessions.get(id)?.checkoutState);

  // Get the full session for other data
  const session = useStore((state) => state.sessions.get(id));

  const {
    contextMenu,
    handleContextMenu,
    handleArchive,
    closeContextMenu,
  } = useAgentNodeState(id, nodeData, session);

  const displayColor = session?.customColor || session?.color || nodeData.color || "#22C55E";
  const displayName = session?.customName || session?.agentName || nodeData.label || "Agent";
  const displayIcon = nodeData.icon || "cpu";

  return (
    <>
      <motion.div
        initial={{ scale: 0.9, opacity: 0 }}
        animate={{ scale: 1, opacity: 1 }}
        onContextMenu={handleContextMenu}
      >
        <AgentNodeCard
          selected={selected}
          displayColor={displayColor}
          displayName={displayName}
          icon={displayIcon}
          agentId={nodeData.agentId}
          connected={connected}
          checkoutState={checkoutState}
          cwd={session?.cwd}
          originalCwd={session?.originalCwd}
          gitBranch={session?.gitBranch}
          ticketId={session?.ticketId}
          ticketTitle={session?.ticketTitle}
        />
      </motion.div>

      {contextMenu && (
        <AgentNodeContextMenu
          position={contextMenu}
          onClose={closeContextMenu}
          onArchive={handleArchive}
        />
      )}
    </>
  );
};
