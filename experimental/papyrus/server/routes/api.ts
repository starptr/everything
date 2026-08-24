import { Hono } from "hono";
import type { Agent } from "../types";
import { randomUUID } from "crypto";
import { PORT } from "../config";
import {
  sessions,
  spawnTerminal,
  killTerminal,
  resolveRuntime,
  pruneWorkstreams,
  HOLDER,
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
    // The backend's listen port, so the client can open the terminal WebSocket
    // directly (in dev the page is served by Vite on a different port, whose WS
    // proxy does not relay frames; in prod this equals the page's own port).
    serverPort: PORT,
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

// The `new` command tree a workstream can be created from (drives the New
// Workstream modal) — pure metadata from `silverwood new-schema`.
apiRoutes.get("/new-schema", async (c) => {
  try {
    return c.json(await sw.newSchema());
  } catch (e: any) {
    logError(`\x1b[38;5;141m[new-schema]\x1b[0m ${e.message}`);
    return c.json({ error: e.message }, 500);
  }
});

// ---- node model: a canvas node IS a silverwood workstream ----

// Project a workstream into the node the client renders. Every durable field is
// read fresh from silverwood; a per-session `sessions[]` list overlays the live
// PTY registry ("connected") and the advisory lock ("mine" = held by this
// instance). papyrus caches no durable data — this is a pure projection.
async function buildNode(ws: sw.Workstream) {
  const kv = ws.kv?.[sw.PAPYRUS_NS] || {};
  const cwd = sw.checkoutLocation(ws) || "";
  const cstate = sw.checkoutState(ws);

  // Live PTYs belonging to this workstream, from the registry.
  const runtimes = [...sessions].filter(([, s]) => s.workstreamId === ws.id);

  // Durable sessions from silverwood, overlaid with liveness + lock.
  let durable: Record<string, sw.AgentSession> = {};
  try {
    durable = await sw.sessionLs(ws.id);
  } catch (e: any) {
    logError(`\x1b[38;5;141m[sessions]\x1b[0m ${ws.id}: ${e.message}`);
  }
  // papyrus records a session durably BEFORE spawning its PTY, so every live PTY has a
  // durable record here — no transient-tab projection is needed.
  const tabs: any[] = [];
  for (const [sid, rec] of Object.entries(durable)) {
    // The registry key IS the session id, so a live PTY is a direct lookup.
    const live = runtimes.some(([k]) => k === sid);
    tabs.push({
      sessionId: sid,
      name: rec.name,
      createdAt: rec.created_at,
      kind: rec.kind,
      connected: live,
      lock: rec.lock ? { holder: rec.lock.holder, mine: rec.lock.holder === HOLDER } : null,
    });
  }

  const position = sw.decodeKv<{ x: number; y: number }>(kv, "position");
  return {
    nodeId: ws.id,
    sessionId: ws.id,
    agentId: "claude",
    agentName: "Claude Code",
    command: "claude",
    cwd,
    createdAt: ws.created_at,
    customName: ws.name,
    customColor: sw.decodeKv<string>(kv, "color"),
    notes: sw.decodeKv<string>(kv, "notes"),
    ...(position ? { position } : {}),
    // Node visuals: is any session connected in THIS papyrus instance, and the
    // checkout state. No live agent-activity status (that needed the hook).
    connected: tabs.some((t) => t.connected),
    checkoutState: cstate,
    // Algebraic state from silverwood + the workstream kind (client gates the
    // "N/M Connected" agent count to Basic workstreams).
    overallState: ws.overall_state,
    kind: ws.kind,
    source: ws.mode?.initial_source,
    sessions: tabs,
  };
}

// List active workstreams as nodes; prune runtime PTYs for workstreams that no
// longer exist (archived/deleted, possibly by another process). Re-reads
// silverwood fresh every call, so the projection tracks concurrent external
// mutations. One `session ls` per workstream — fine at personal scale.
async function hydrateNodes() {
  const wss = await sw.list();
  pruneWorkstreams(new Set(wss.map((w) => w.id)));
  return Promise.all(wss.map(buildNode));
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

// Record a fresh durable session in silverwood BEFORE its PTY is spawned — `spawn from-id`
// reads the record to know how to run it, so the create is mandatory: this THROWS on failure
// and the caller must not spawn without a record. papyrus mints the id (for a claude session it
// is also the `claude --session-id`). For a claude kind it additionally acquires the advisory
// lock (best-effort — advisory, so it never blocks the spawn). Returns whether the lock is held.
async function recordFreshSession(
  variant: "claude-code" | "plain-shell",
  wsId: string,
  sessionId: string,
): Promise<boolean> {
  if (variant === "plain-shell") {
    await sw.sessionCreate("plain-shell", wsId, sessionId, "shell");
    return false;
  }
  await sw.sessionCreate("claude-code", wsId, sessionId, "claude");
  try {
    await sw.sessionLock(wsId, sessionId, HOLDER);
    return true;
  } catch (e: any) {
    logError(`\x1b[38;5;141m[session-register]\x1b[0m lock ${sessionId}: ${e.message}`);
    return false;
  }
}

// Create a node = register a silverwood workstream, then respond at the accept
// boundary so the New Workstream modal closes immediately. The (possibly slow) checkout
// is provisioned in the BACKGROUND; the node appears pending → ready/failed via the
// reconcile loop. No agent session is attached — a fresh workstream starts bare; the
// user adds one from the sidebar. Only a synchronous validation error keeps the modal
// open (a 400 below).
apiRoutes.post("/sessions", async (c) => {
  const body = await c.req.json();
  const { name, path, args, position, source } = body;
  if (!name || !Array.isArray(path) || path.length === 0) {
    return c.json({ error: "name and a checkout path are required" }, 400);
  }

  // A positional may reference an existing workstream instead of a literal value
  // (e.g. an apfs-cow source). silverwood only takes a filesystem path, and papyrus is
  // stateless, so resolve the workstream's checkout path *now* from live silverwood
  // (`show`) rather than trusting a client-cached value, then pass it verbatim.
  const argList = Array.isArray(args) ? [...args] : [];
  if (source && Number.isInteger(source.argIndex) && source.argIndex >= 0) {
    let srcWs: sw.Workstream;
    try {
      srcWs = await sw.get(source.workstreamId);
    } catch (e: any) {
      return c.json({ error: e.message }, 400);
    }
    const srcPath = sw.checkoutLocation(srcWs);
    if (!srcPath) return c.json({ error: "selected workstream has no checkout path" }, 400);
    argList[source.argIndex] = srcPath;
  }

  let ws: sw.Workstream;
  try {
    ws = await sw.create({ name, path, args: argList });
  } catch (e: any) {
    logError(`\x1b[38;5;141m[create]\x1b[0m ${e.message}`);
    return c.json({ error: e.message }, 400);
  }

  if (position) await sw.setKv(ws.id, "position", position);

  const cwd = sw.checkoutLocation(ws) || "";

  // Provision the checkout in the background — deliberately NOT awaited, so the response
  // returns now (modal closes). The node appears pending → ready/failed on the canvas via
  // reconcile. No session is attached on create: a fresh workstream starts with zero
  // sessions; the user adds one from the sidebar ("+" / "Start a session"). A provisioning
  // failure surfaces as `basic.failed` on the canvas via reconcile, not here.
  //
  // Only a workstream awaiting a checkout needs provisioning — i.e. a `basic` kind created
  // with `--checkout-extent skip` (`mode.state === "initialized-without-checkout"`). The
  // `local-*` kinds have no checkout mode and are ready on create, so skip the (basic-only)
  // `checkout` call, which would otherwise error on their non-basic kind.
  const wsId = ws.id;
  if (ws.mode?.state === "initialized-without-checkout") {
    sw.checkout(wsId).catch((e: any) => {
      logError(`\x1b[38;5;141m[checkout]\x1b[0m ${wsId}: ${e.message}`);
    });
  }

  return c.json({
    sessionId: ws.id,
    nodeId: ws.id,
    cwd,
    checkoutState: sw.checkoutState(ws),
  });
});

// Connect (reopen) an existing durable session: acquire its advisory lock (claude kinds
// only), then spawn its PTY via `spawn from-id` — silverwood runs it the way it records
// itself (a shell reopens fresh; a claude session resumes if a transcript exists, else
// starts fresh). `force` steals a claude lock held elsewhere.
apiRoutes.post("/sessions/:wsId/sessions/connect", async (c) => {
  const wsId = c.req.param("wsId");
  const { sessionId, force } = await c.req.json();
  if (!sessionId) return c.json({ error: "sessionId is required" }, 400);

  // Already live in this process? Just report it.
  const existing = resolveRuntime(sessionId);
  if (existing && existing[1].workstreamId === wsId) {
    return c.json({ sessionId: existing[0], connected: true });
  }

  let ws: sw.Workstream;
  try {
    ws = await sw.get(wsId);
  } catch (e: any) {
    return c.json({ error: e.message }, 404);
  }
  const cwd = sw.checkoutLocation(ws) || "";
  if (!cwd || sw.checkoutState(ws) !== "ready") {
    return c.json({ error: "checkout not ready" }, 400);
  }

  // silverwood is authoritative for the session's kind (the tab may be stale). A shell
  // kind carries no lock; a claude kind acquires the advisory lock. Either way the PTY is
  // a uniform `spawn from-id`, and silverwood decides how to run it (a shell reopens fresh;
  // a claude session resumes if a transcript exists, else starts fresh).
  const durable = await sw
    .sessionLs(wsId)
    .catch(() => ({}) as Record<string, sw.AgentSession>);
  const isShell = durable[sessionId]?.kind === "plain-shell";

  // Acquire the advisory lock (claude kinds only). A contention failure → 409 so the UI
  // can offer Force; any other silverwood error is logged and ignored (the lock is
  // advisory, so it must never block a connect on its own).
  let holdsLock = false;
  if (!isShell) {
    try {
      await sw.sessionLock(wsId, sessionId, HOLDER, !!force);
      holdsLock = true;
    } catch (e: any) {
      const m = /is locked by (.+)$/.exec((e.message || "").trim());
      if (m) return c.json({ error: e.message, locked: true, holder: m[1] }, 409);
      log(`\x1b[38;5;141m[lock]\x1b[0m acquire ${sessionId}: ${e.message}`);
    }
  }

  const session = spawnTerminal({
    sessionKey: sessionId,
    workstreamId: wsId,
    cwd,
    kind: isShell ? "plain-shell" : "claude-code",
  });
  session.holdsLock = holdsLock;
  log(`\x1b[38;5;141m[session]\x1b[0m connected ${sessionId}`);
  return c.json({ sessionId, connected: true });
});

// Add a fresh session tab of the requested `variant` (body `{ variant }`, default
// "claude-code"). papyrus mints the id and records the durable silverwood session FIRST
// (so `spawn from-id` can read it), then spawns its PTY — so the tab (and any rename)
// persists workstream-scoped. A claude kind also acquires its advisory lock; a plain shell
// carries none and reopens fresh. A record failure fails the request (nothing is spawned).
apiRoutes.post("/sessions/:wsId/sessions", async (c) => {
  const wsId = c.req.param("wsId");
  const body = await c.req.json().catch(() => ({}));
  const variant = body.variant === "plain-shell" ? "plain-shell" : "claude-code";
  let ws: sw.Workstream;
  try {
    ws = await sw.get(wsId);
  } catch (e: any) {
    return c.json({ error: e.message }, 404);
  }
  const cwd = sw.checkoutLocation(ws) || "";
  if (!cwd || sw.checkoutState(ws) !== "ready") {
    return c.json({ error: "checkout not ready" }, 400);
  }
  const sessionId = randomUUID();
  let holdsLock: boolean;
  try {
    holdsLock = await recordFreshSession(variant, wsId, sessionId);
  } catch (e: any) {
    logError(`\x1b[38;5;141m[session]\x1b[0m record ${variant} ${sessionId}: ${e.message}`);
    return c.json({ error: e.message }, 500);
  }
  const session = spawnTerminal({ sessionKey: sessionId, workstreamId: wsId, cwd, kind: variant });
  session.holdsLock = holdsLock;
  log(`\x1b[38;5;141m[session]\x1b[0m spawned fresh ${variant} ${sessionId}`);
  return c.json({ sessionId, connected: true, variant });
});

// Disconnect a session: kill its live PTY (releasing the lock). The durable
// silverwood session is untouched, so the tab remains (disconnected).
apiRoutes.post("/sessions/:wsId/sessions/:sessionId/disconnect", (c) => {
  const r = resolveRuntime(c.req.param("sessionId"));
  if (r) killTerminal(r[0]);
  return c.json({ success: true });
});

// Remove a session entirely: kill its live PTY (if any) and delete the durable
// silverwood record, so the tab is gone for good. This is how any tab is closed for
// good — a plain shell, or a claude session you no longer want.
apiRoutes.delete("/sessions/:wsId/sessions/:sessionId", async (c) => {
  const wsId = c.req.param("wsId");
  const sessionId = c.req.param("sessionId");
  const r = resolveRuntime(sessionId);
  if (r) killTerminal(r[0]);
  try {
    await sw.sessionRemove(wsId, sessionId);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
  }
  return c.json({ success: true });
});

// Rename a session (its silverwood `name`, shown as the tab title). Name required
// and non-empty; the live PTY (if any) is untouched.
apiRoutes.patch("/sessions/:wsId/sessions/:sessionId", async (c) => {
  const wsId = c.req.param("wsId");
  const sessionId = c.req.param("sessionId");
  const { name } = await c.req.json();
  if (typeof name !== "string" || !name.trim()) {
    return c.json({ error: "name is required" }, 400);
  }
  try {
    await sw.sessionRename(wsId, sessionId, name);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
  }
  return c.json({ success: true });
});

// Edit a node's label/color/notes/position. Label is the workstream name (silverwood
// rename); color, notes, and canvas position are papyrus KV. Position is per-node —
// the client saves only the workstream it moved, so one instance never rewrites another's.
apiRoutes.patch("/sessions/:sessionId", async (c) => {
  const id = c.req.param("sessionId");
  const u = await c.req.json();
  try {
    if (u.customName !== undefined) await sw.rename(id, u.customName);
    if (u.customColor !== undefined) await sw.setKv(id, "color", u.customColor);
    if (u.notes !== undefined) await sw.setKv(id, "notes", u.notes);
    if (u.position !== undefined) await sw.setKv(id, "position", u.position);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
  }
  return c.json({ success: true });
});

// Delete a node = kill all its terminals (releasing their locks) + archive the
// workstream (tombstone).
apiRoutes.delete("/sessions/:sessionId", async (c) => {
  const id = c.req.param("sessionId");
  for (const [key, s] of [...sessions]) {
    if (s.workstreamId === id) killTerminal(key);
  }
  try {
    await sw.archive(id);
  } catch (e: any) {
    return c.json({ error: e.message }, 400);
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
