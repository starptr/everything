import { useEffect, useCallback, useRef } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  useNodesState,
  BackgroundVariant,
  ReactFlowProvider,
  NodeChange,
  applyNodeChanges,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { Plus } from "lucide-react";

import { useStore, AgentSession } from "./stores/useStore";
import { AgentNode } from "./components/AgentNode/index";
import { Sidebar } from "./components/Sidebar";
import { NewSessionModal } from "./components/NewSessionModal";
import { Header } from "./components/Header";
import { CanvasControls } from "./components/CanvasControls";

const nodeTypes = {
  agent: AgentNode,
};

function AppContent() {
  const {
    nodes: storeNodes,
    setNodes: setStoreNodes,
    setAgents,
    setLaunchCwd,
    setServerPort,
    setSelectedNodeId,
    setSidebarOpen,
    agents,
    addAgentModalOpen,
    setAddAgentModalOpen,
  } = useStore();

  const [nodes, setNodes, onNodesChange] = useNodesState(storeNodes);
  const positionUpdateTimeout = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hasRestoredRef = useRef(false);
  // True while a node is being dragged, so the reconcile loop doesn't touch nodes
  // (and snap a drag back). Session/tab updates still flow.
  const draggingRef = useRef(false);

  // Sync nodes with store
  useEffect(() => {
    setStoreNodes(nodes);
  }, [nodes, setStoreNodes]);

  useEffect(() => {
    if (storeNodes.length > 0 || hasRestoredRef.current) {
      setNodes(storeNodes);
    }
  }, [storeNodes, setNodes]);

  // Fetch config, agents, and restore state on mount
  useEffect(() => {
    fetch("/api/config")
      .then((res) => res.json())
      .then((config) => {
        setLaunchCwd(config.launchCwd);
        setServerPort(config.serverPort ?? null);
      })
      .catch(console.error);

    fetch("/api/agents")
      .then((res) => res.json())
      .then((agents) => setAgents(agents))
      .catch(console.error);
  }, [setAgents, setLaunchCwd, setServerPort]);

  // Reconcile the client's view from silverwood every second. GET /api/state is a
  // fresh projection (workstreams + per-session tabs + lock), so nodes/tabs/names
  // appear, disappear, and update as the forest changes — including from other
  // processes. The client invents no durable state. An existing node's position is
  // never pulled from the server (positions flow client -> server on drag), so this
  // never fights a drag; node mutations are also skipped while a drag is in flight.
  useEffect(() => {
    if (agents.length === 0) return;
    let cancelled = false;

    const reconcile = async () => {
      let serverNodes: any[];
      try {
        const res = await fetch("/api/state");
        if (!res.ok) return;
        serverNodes = (await res.json()).nodes;
      } catch {
        return;
      }
      if (cancelled || !Array.isArray(serverNodes)) return;

      const store = useStore.getState();
      const dragging = draggingRef.current;
      const serverIds = new Set<string>();

      serverNodes.forEach((n: any, index: number) => {
        serverIds.add(n.nodeId);
        const agent = store.agents.find((a) => a.id === n.agentId);
        const color = n.customColor || agent?.color || "#888";
        const label = n.customName || n.agentName;
        const sessionData = {
          id: n.nodeId,
          sessionId: n.sessionId,
          agentId: n.agentId,
          agentName: n.agentName,
          command: n.command,
          color,
          createdAt: n.createdAt,
          cwd: n.cwd,
          connected: !!n.connected,
          checkoutState: n.checkoutState,
          customName: n.customName,
          customColor: n.customColor,
          notes: n.notes,
          tabs: (n.sessions || []) as AgentSession["tabs"],
        };

        if (store.sessions.has(n.nodeId)) {
          store.updateSession(n.nodeId, sessionData);
          if (dragging) return;
          // Reflect an external rename/recolor on the canvas node label.
          const node = store.nodes.find((x) => x.id === n.nodeId);
          if (node && (node.data?.label !== label || node.data?.color !== color)) {
            store.updateNode(n.nodeId, { data: { ...node.data, label, color } });
          }
        } else if (!dragging) {
          store.addSession(n.nodeId, sessionData);
          const position =
            n.position && typeof n.position.x === "number"
              ? n.position
              : { x: 100 + (index % 5) * 220, y: 100 + Math.floor(index / 5) * 150 };
          store.addNode({
            id: n.nodeId,
            type: "agent",
            position,
            data: { label, agentId: n.agentId, color, icon: agent?.icon || "cpu", sessionId: n.sessionId },
          });
        }
      });

      // Drop workstreams that vanished (archived/deleted, possibly elsewhere).
      if (!dragging) {
        for (const id of [...store.sessions.keys()]) {
          if (!serverIds.has(id)) {
            store.removeSession(id);
            store.removeNode(id);
          }
        }
      }
      hasRestoredRef.current = true;
    };

    reconcile();
    const interval = setInterval(reconcile, 1000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [agents.length]);

  // Helper to save all positions - accepts nodes directly to avoid sync issues
  const saveAllPositions = useCallback((nodesToSave?: typeof nodes) => {
    const currentNodes = nodesToSave || useStore.getState().nodes;
    if (currentNodes.length === 0) return;

    const positions: Record<string, { x: number; y: number }> = {};
    const GRID_SIZE = 24;
    currentNodes.forEach((node) => {
      // Each node is a workstream; its coordinate is saved to the workstream's KV.
      if (node.type === "agent") {
        positions[node.id] = {
          x: Math.round(node.position.x / GRID_SIZE) * GRID_SIZE,
          y: Math.round(node.position.y / GRID_SIZE) * GRID_SIZE,
        };
      }
    });
    if (Object.keys(positions).length > 0) {
      fetch("/api/state/positions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ positions }),
      }).catch(console.error);
    }
  }, [nodes]);

  // Save positions on window close/refresh
  useEffect(() => {
    const handleBeforeUnload = () => {
      saveAllPositions();
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, [saveAllPositions]);

  // Save positions when nodes are moved or resized
  const handleNodesChange = useCallback((changes: NodeChange[]) => {
    onNodesChange(changes);

    // Track drag state so the reconcile loop leaves nodes alone mid-drag.
    for (const c of changes) {
      if (c.type === "position" && "dragging" in c) {
        draggingRef.current = c.dragging === true;
      }
    }

    const positionChanges = changes.filter(
      (c) => c.type === "position" && "dragging" in c && c.dragging === false
    );
    // Check for dimension changes - resizing property might be true, false, or undefined
    const dimensionChanges = changes.filter(
      (c) => c.type === "dimensions" && (!("resizing" in c) || c.resizing === false)
    );

    if (positionChanges.length > 0 || dimensionChanges.length > 0) {
      if (positionUpdateTimeout.current) {
        clearTimeout(positionUpdateTimeout.current);
      }
      // Compute updated nodes immediately to avoid sync delay issues
      const updatedNodes = applyNodeChanges(changes, nodes);
      positionUpdateTimeout.current = setTimeout(() => {
        saveAllPositions(updatedNodes);
      }, 300);
    }
  }, [onNodesChange, saveAllPositions, nodes]);

  const onNodeClick = useCallback(
    (_: React.MouseEvent, node: any) => {
      // Only open sidebar for agent nodes
      if (node.type === "agent") {
        setSelectedNodeId(node.id);
        setSidebarOpen(true);
      }
    },
    [setSelectedNodeId, setSidebarOpen]
  );

  const onPaneClick = useCallback(() => {
    setSelectedNodeId(null);
    setSidebarOpen(false);
  }, [setSelectedNodeId, setSidebarOpen]);

  const isEmpty = nodes.length === 0;

  return (
    <div className="w-screen h-screen bg-canvas overflow-hidden flex flex-col">
      <Header />

      <div className="flex-1 relative">
        <ReactFlow
          nodes={nodes}
          edges={[]}
          onNodesChange={handleNodesChange}
          onNodeClick={onNodeClick}
          onPaneClick={onPaneClick}
          nodeTypes={nodeTypes}
          fitView
          proOptions={{ hideAttribution: true }}
          minZoom={0.3}
          maxZoom={2}
          nodesDraggable
          nodesConnectable={false}
          snapToGrid
          snapGrid={[24, 24]}
        >
          <Background
            variant={BackgroundVariant.Dots}
            gap={24}
            size={1}
            color="#252525"
          />
          <Controls
            showInteractive={false}
            position="bottom-left"
          />
          <CanvasControls />
        </ReactFlow>

        {/* Empty state */}
        {isEmpty && (
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            <div className="text-center pointer-events-auto">
              <div className="w-16 h-16 rounded-2xl bg-surface border border-border flex items-center justify-center mx-auto mb-4">
                <Plus className="w-8 h-8 text-zinc-600" />
              </div>
              <h2 className="text-lg font-medium text-zinc-300 mb-2">No agents yet</h2>
              <p className="text-sm text-zinc-500 mb-4 max-w-xs">
                Spawn your first AI agent to get started
              </p>
              <button
                onClick={() => setAddAgentModalOpen(true)}
                className="px-4 py-2 rounded-lg bg-white text-canvas font-medium text-sm hover:bg-zinc-100 transition-colors"
              >
                Create Agent
              </button>
            </div>
          </div>
        )}

        <Sidebar />
      </div>

      <NewSessionModal open={addAgentModalOpen} onClose={() => setAddAgentModalOpen(false)} />
    </div>
  );
}

function App() {
  return (
    <ReactFlowProvider>
      <AppContent />
    </ReactFlowProvider>
  );
}

export default App;
