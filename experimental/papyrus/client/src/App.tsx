import { useEffect, useCallback, useRef, useMemo } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  useNodesState,
  BackgroundVariant,
  ReactFlowProvider,
  type Node,
  type NodeChange,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { Plus } from "lucide-react";

import { useStore, AgentSession } from "./stores/useStore";
import { resolveReconciledPosition } from "./canvasPosition";
import { AgentNode } from "./components/AgentNode/index";
import { Sidebar } from "./components/Sidebar";
import { SettingsPanel } from "./components/SettingsPanel";
import { NewSessionModal } from "./components/NewSessionModal";
import { Header } from "./components/Header";
import { CanvasControls } from "./components/CanvasControls";
import { useThemeController } from "./hooks/useThemeController";

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

  useThemeController();

  // The canvas dot-grid color comes from React Flow as an SVG `fill` attribute, which
  // can't reference a CSS var — so read the resolved `--color-dot` token instead, and
  // recompute whenever the active theme changes.
  const resolvedTheme = useStore((s) => s.resolvedTheme);
  const dotColor = useMemo(() => {
    if (typeof window === "undefined") return "rgb(37 37 37)";
    const v = getComputedStyle(document.documentElement).getPropertyValue("--color-dot").trim();
    return v ? `rgb(${v})` : "rgb(37 37 37)";
  }, [resolvedTheme]);

  const [nodes, setNodes, onNodesChange] = useNodesState(storeNodes);
  // A node just moved locally: keep its optimistic position and shield it from the
  // reconcile loop until silverwood echoes back the value we saved (the expiry is only
  // a failure-mode safety valve — see the reconcile's echo-clear guard below).
  const recentlyMoved = useRef<Map<string, { x: number; y: number; expiry: number }>>(
    new Map(),
  );
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
  // processes. The client invents no durable state: silverwood is authoritative for
  // position too, so an existing node's position is re-synced from the server (that is
  // how a move in another instance shows up here). The only exception is a node we just
  // dragged ourselves — `recentlyMoved` keeps its optimistic position until our own save
  // echoes back — and all node mutations are skipped while a drag is in flight.
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
          const node = store.nodes.find((x) => x.id === n.nodeId);
          if (!node) return;

          const updates: Partial<Node> = {};
          // Reflect an external rename/recolor on the canvas node label.
          if (node.data?.label !== label || node.data?.color !== color) {
            updates.data = { ...node.data, label, color };
          }
          // Adopt silverwood's position (source of truth), except for a node we just
          // dragged, until our own save echoes back (see resolveReconciledPosition).
          const { position, clearGuard } = resolveReconciledPosition(
            node.position,
            n.position,
            recentlyMoved.current.get(n.nodeId),
            Date.now(),
          );
          if (clearGuard) recentlyMoved.current.delete(n.nodeId);
          if (position) updates.position = position;
          if (updates.data || updates.position) {
            store.updateNode(n.nodeId, updates);
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

  // Persist a finished drag straight to silverwood — only the node(s) that moved, so one
  // instance never rewrites another's positions. A selection drag fires once with every
  // dragged node in `dragged`. React Flow snaps to the grid, so `position` is already
  // grid-aligned; sending it verbatim lets the reconcile's echo-check match exactly.
  const onNodeDragStop = useCallback(
    (_: React.MouseEvent, _node: Node, dragged: Node[]) => {
      const moved = dragged?.length ? dragged : [_node];
      const GRACE = 10_000;
      for (const n of moved) {
        if (n.type !== "agent") continue;
        const position = { x: n.position.x, y: n.position.y };
        recentlyMoved.current.set(n.id, { ...position, expiry: Date.now() + GRACE });
        fetch(`/api/sessions/${n.id}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ position }),
          keepalive: true, // survive a tab close that races the drop
        }).catch(console.error);
      }
    },
    [],
  );

  const handleNodesChange = useCallback(
    (changes: NodeChange[]) => {
      onNodesChange(changes);
      // Track drag state so the reconcile loop leaves nodes alone mid-drag.
      for (const c of changes) {
        if (c.type === "position" && "dragging" in c) {
          draggingRef.current = c.dragging === true;
        }
      }
    },
    [onNodesChange],
  );

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
          onNodeDragStop={onNodeDragStop}
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
            color={dotColor}
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
                <Plus className="w-8 h-8 text-content-faint" />
              </div>
              <h2 className="text-lg font-medium text-content mb-2">No agents yet</h2>
              <p className="text-sm text-content-subtle mb-4 max-w-xs">
                Spawn your first AI agent to get started
              </p>
              <button
                onClick={() => setAddAgentModalOpen(true)}
                className="px-4 py-2 rounded-lg bg-inverse text-inverse-content font-medium text-sm hover:bg-inverse/90 transition-colors"
              >
                Create Agent
              </button>
            </div>
          </div>
        )}

        <Sidebar />
        <SettingsPanel />
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
