import { Hono } from "hono";
import type { Agent } from "../types";
import {
  sessions,
  spawnTerminal,
  killTerminal,
  ensureDormant,
} from "../services/sessionManager";
import * as sw from "../services/silverwood";
import {
  loadConfig,
  fetchTeams,
  fetchMyTickets,
  searchTickets,
  fetchTicketByIdentifier,
} from "../services/linear";

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);
const logError = QUIET ? () => {} : console.error.bind(console);

export const apiRoutes = new Hono();

apiRoutes.get("/config", (c) => {
  return c.json({
    launchCwd: process.env.LAUNCH_CWD || process.cwd(),
    forest: process.env.SILVERWOOD_FOREST_PATH || null,
  });
});

apiRoutes.get("/agents", (c) => {
  // Today silverwood only models the `claude-code` session kind, so a node runs
  // Claude Code. Other agents return as future session kinds.
  const agents: Agent[] = [
    {
      id: "claude",
      name: "Claude Code",
      command: "claude",
      description: "Anthropic's official CLI for Claude",
      color: "#F97316",
      icon: "sparkles",
    },
  ];
  return c.json(agents);
});

// ---- node model: a canvas node IS a silverwood workstream ----

// Project a workstream (+ its runtime terminal, if any) into the node shape the
// client renders. Presentation state comes from papyrus's KV namespace; the
// display name is the workstream name.
function buildNode(ws: sw.Workstream) {
  const kv = ws.kv?.[sw.PAPYRUS_NS] || {};
  const runtime = sessions.get(ws.id);
  const cwd = sw.checkoutLocation(ws) || "";
  const cstate = sw.checkoutState(ws);
  const status = runtime?.pty
    ? runtime.status
    : cstate === "failed"
      ? "error"
      : cstate === "pending"
        ? "idle"
        : "disconnected";
  const position = sw.decodeKv<{ x: number; y: number }>(kv, "position");
  return {
    nodeId: ws.id,
    sessionId: ws.id,
    agentId: runtime?.agentId || "claude",
    agentName: runtime?.agentName || "Claude Code",
    command: runtime?.command || "claude",
    cwd,
    createdAt: ws.created_at,
    customName: ws.name,
    customColor: sw.decodeKv<string>(kv, "color"),
    notes: sw.decodeKv<string>(kv, "notes"),
    ...(position ? { position } : {}),
    status,
    isAlive: true,
    isRestored: !runtime?.pty,
    checkoutState: cstate,
    source: ws.mode?.initial_source,
  };
}

// List active workstreams as nodes; ensure a dormant runtime entry per node; prune
// runtime entries for workstreams that no longer exist (archived/deleted).
async function hydrateNodes() {
  const wss = await sw.list();
  const alive = new Set(wss.map((w) => w.id));
  for (const id of [...sessions.keys()]) {
    if (!alive.has(id)) killTerminal(id);
  }
  for (const ws of wss) ensureDormant(ws.id, sw.checkoutLocation(ws) || "");
  return wss.map(buildNode);
}

apiRoutes.get("/state", async (c) => {
  try {
    return c.json({ nodes: await hydrateNodes() });
  } catch (e: any) {
    logError(`\x1b[38;5;141m[state]\x1b[0m ${e.message}`);
    return c.json({ nodes: [], error: e.message }, 500);
  }
});

apiRoutes.get("/sessions", async (c) => {
  try {
    return c.json(await hydrateNodes());
  } catch (e: any) {
    logError(`\x1b[38;5;141m[sessions]\x1b[0m ${e.message}`);
    return c.json([]);
  }
});

apiRoutes.get("/sessions/:sessionId/status", (c) => {
  const s = sessions.get(c.req.param("sessionId"));
  if (!s) return c.json({ status: "disconnected", isRestored: true });
  return c.json({ status: s.status, isRestored: s.isRestored });
});

// Create a node = create a silverwood workstream (clones its checkout), then spawn
// its Claude Code terminal. Blocks on the clone; the node comes up ready.
apiRoutes.post("/sessions", async (c) => {
  const body = await c.req.json();
  const { name, source, mode, position } = body;
  if (!name || !source) {
    return c.json({ error: "name and source (an https git url) are required" }, 400);
  }

  let ws: sw.Workstream;
  try {
    ws = await sw.create({ name, source, mode });
  } catch (e: any) {
    logError(`\x1b[38;5;141m[create]\x1b[0m ${e.message}`);
    return c.json({ error: e.message }, 400);
  }

  if (position) await sw.setKv(ws.id, "position", position);

  const cwd = sw.checkoutLocation(ws) || "";
  if (sw.checkoutState(ws) === "ready" && cwd) {
    spawnTerminal({
      workstreamId: ws.id,
      cwd,
      agentId: "claude",
      agentName: "Claude Code",
      command: "claude",
    });
  } else {
    ensureDormant(ws.id, cwd);
  }

  return c.json({
    sessionId: ws.id,
    nodeId: ws.id,
    cwd,
    checkoutState: sw.checkoutState(ws),
  });
});

// Spawn (or respawn) a node's terminal — the "Spawn Fresh" action.
apiRoutes.post("/sessions/:sessionId/restart", async (c) => {
  const id = c.req.param("sessionId");
  let ws: sw.Workstream;
  try {
    ws = await sw.get(id);
  } catch (e: any) {
    return c.json({ error: e.message }, 404);
  }
  const cwd = sw.checkoutLocation(ws) || "";
  if (!cwd || sw.checkoutState(ws) !== "ready") {
    return c.json({ error: "checkout not ready" }, 400);
  }
  const existing = sessions.get(id);
  spawnTerminal({
    workstreamId: id,
    cwd,
    agentId: existing?.agentId || "claude",
    agentName: existing?.agentName || "Claude Code",
    command: existing?.command || "claude",
  });
  log(`\x1b[38;5;141m[session]\x1b[0m spawned ${id}`);
  return c.json({ success: true });
});

// Persist canvas positions into each workstream's papyrus KV (serialized writes).
apiRoutes.post("/state/positions", async (c) => {
  const { positions } = await c.req.json();
  await Promise.all(
    Object.entries(positions || {}).map(([id, pos]) => sw.setKv(id, "position", pos)),
  );
  return c.json({ success: true });
});

// Edit a node's label/color/notes. Label is the workstream name (silverwood
// rename); color + notes are papyrus KV.
apiRoutes.patch("/sessions/:sessionId", async (c) => {
  const id = c.req.param("sessionId");
  const u = await c.req.json();
  try {
    if (u.customName !== undefined) await sw.rename(id, u.customName);
    if (u.customColor !== undefined) await sw.setKv(id, "color", u.customColor);
    if (u.notes !== undefined) await sw.setKv(id, "notes", u.notes);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
  }
  return c.json({ success: true });
});

// Delete a node = kill its terminal + archive the workstream (tombstone).
apiRoutes.delete("/sessions/:sessionId", async (c) => {
  const id = c.req.param("sessionId");
  killTerminal(id);
  try {
    await sw.archive(id);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
  }
  return c.json({ success: true });
});

// Status update endpoint for the Claude Code plugin. Purely in-memory, except
// that the first time we learn a Claude session id we record a silverwood session.
apiRoutes.post("/status-update", async (c) => {
  const body = await c.req.json();
  const { status, openuiSessionId, claudeSessionId, hookEvent, toolName } = body;

  log(
    `\x1b[38;5;82m[plugin-hook]\x1b[0m ${hookEvent || "unknown"}: status=${status} tool=${toolName || "none"} openui=${openuiSessionId || "none"}`,
  );

  if (!status) return c.json({ error: "status is required" }, 400);

  let foundId: string | undefined;
  let session = openuiSessionId ? sessions.get(openuiSessionId) : undefined;
  if (session) foundId = openuiSessionId;
  if (!session && claudeSessionId) {
    for (const [id, s] of sessions) {
      if (s.claudeSessionId === claudeSessionId) {
        session = s;
        foundId = id;
        break;
      }
    }
  }

  if (!session || !foundId) {
    return c.json({ success: true, warning: "No matching session found" });
  }

  if (claudeSessionId && !session.claudeSessionId) {
    session.claudeSessionId = claudeSessionId;
  }
  // Record the agent session in silverwood once (fire-and-forget).
  if (claudeSessionId && !session.silverwoodSessionRecorded) {
    session.silverwoodSessionRecorded = true;
    sw.sessionCreate(foundId, claudeSessionId, session.agentName || "claude").catch((e) =>
      log(`\x1b[38;5;141m[session-register]\x1b[0m ${e.message}`),
    );
  }

  // Permission detection: a PreToolUse with no matching PostToolUse within 2.5s
  // means the agent is waiting for the user to grant permission.
  let effectiveStatus = status;
  if (status === "pre_tool") {
    effectiveStatus = "running";
    session.currentTool = toolName;
    session.preToolTime = Date.now();
    if (session.permissionTimeout) clearTimeout(session.permissionTimeout);
    session.permissionTimeout = setTimeout(() => {
      if (session!.preToolTime) {
        session!.status = "waiting_input";
        for (const client of session!.clients) {
          if (client.readyState === 1) {
            client.send(
              JSON.stringify({
                type: "status",
                status: "waiting_input",
                isRestored: session!.isRestored,
                currentTool: session!.currentTool,
                hookEvent: "permission_timeout",
              }),
            );
          }
        }
      }
    }, 2500);
  } else if (status === "post_tool") {
    effectiveStatus = "running";
    session.preToolTime = undefined;
    if (session.permissionTimeout) {
      clearTimeout(session.permissionTimeout);
      session.permissionTimeout = undefined;
    }
  } else {
    if (status !== "tool_calling" && status !== "running") {
      session.currentTool = undefined;
    }
    session.preToolTime = undefined;
    if (session.permissionTimeout) {
      clearTimeout(session.permissionTimeout);
      session.permissionTimeout = undefined;
    }
  }

  session.status = effectiveStatus;
  session.pluginReportedStatus = true;
  session.lastPluginStatusTime = Date.now();
  session.lastHookEvent = hookEvent;

  for (const client of session.clients) {
    if (client.readyState === 1) {
      client.send(
        JSON.stringify({
          type: "status",
          status: session.status,
          isRestored: session.isRestored,
          currentTool: session.currentTool,
          hookEvent,
        }),
      );
    }
  }

  return c.json({ success: true });
});

// ============ Linear (read-only; API key from $LINEAR_API_KEY) ============

apiRoutes.get("/linear/config", (c) => {
  const config = loadConfig();
  return c.json({
    hasApiKey: !!config.apiKey,
    defaultTeamId: config.defaultTeamId,
  });
});

apiRoutes.get("/linear/teams", async (c) => {
  const config = loadConfig();
  if (!config.apiKey) return c.json({ error: "Linear not configured" }, 400);
  try {
    return c.json(await fetchTeams(config.apiKey));
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

apiRoutes.get("/linear/tickets", async (c) => {
  const config = loadConfig();
  if (!config.apiKey) return c.json({ error: "Linear not configured" }, 400);
  const teamId = c.req.query("teamId") || config.defaultTeamId;
  try {
    return c.json(await fetchMyTickets(config.apiKey, teamId));
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

apiRoutes.get("/linear/search", async (c) => {
  const config = loadConfig();
  if (!config.apiKey) return c.json({ error: "Linear not configured" }, 400);
  const query = c.req.query("q");
  if (!query) return c.json({ error: "Search query required" }, 400);
  const teamId = c.req.query("teamId") || config.defaultTeamId;
  try {
    return c.json(await searchTickets(config.apiKey, query, teamId));
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

apiRoutes.get("/linear/ticket/:identifier", async (c) => {
  const config = loadConfig();
  if (!config.apiKey) return c.json({ error: "Linear not configured" }, 400);
  try {
    const ticket = await fetchTicketByIdentifier(config.apiKey, c.req.param("identifier"));
    if (!ticket) return c.json({ error: "Ticket not found" }, 404);
    return c.json(ticket);
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

// ============ GitHub (stateless public-repo proxies) ============
import {
  fetchGitHubIssues,
  fetchGitHubIssue,
  searchGitHubIssues,
  parseGitHubUrl,
} from "../services/github";

apiRoutes.get("/github/issues", async (c) => {
  const owner = c.req.query("owner");
  const repo = c.req.query("repo");
  const repoUrl = c.req.query("repoUrl");
  let resolvedOwner = owner;
  let resolvedRepo = repo;
  if (repoUrl && !owner && !repo) {
    const parsed = parseGitHubUrl(repoUrl);
    if (!parsed) return c.json({ error: "Invalid GitHub URL" }, 400);
    resolvedOwner = parsed.owner;
    resolvedRepo = parsed.repo;
  }
  if (!resolvedOwner || !resolvedRepo) {
    return c.json({ error: "owner and repo are required (or provide repoUrl)" }, 400);
  }
  try {
    return c.json(await fetchGitHubIssues(resolvedOwner, resolvedRepo));
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

apiRoutes.get("/github/search", async (c) => {
  const owner = c.req.query("owner");
  const repo = c.req.query("repo");
  const q = c.req.query("q");
  if (!owner || !repo) return c.json({ error: "owner and repo are required" }, 400);
  if (!q) return c.json({ error: "Search query (q) is required" }, 400);
  try {
    return c.json(await searchGitHubIssues(owner, repo, q));
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});

apiRoutes.get("/github/issue/:owner/:repo/:number", async (c) => {
  const owner = c.req.param("owner");
  const repo = c.req.param("repo");
  const number = parseInt(c.req.param("number"), 10);
  if (isNaN(number)) return c.json({ error: "Invalid issue number" }, 400);
  try {
    const issue = await fetchGitHubIssue(owner, repo, number);
    if (!issue) return c.json({ error: "Issue not found" }, 404);
    return c.json(issue);
  } catch (e: any) {
    return c.json({ error: e.message }, 500);
  }
});
