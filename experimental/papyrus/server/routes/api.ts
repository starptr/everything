import { Hono } from "hono";
import type { Agent, Session } from "../types";
import { randomUUID } from "crypto";
import { PORT } from "../config";
import {
  sessions,
  spawnTerminal,
  killTerminal,
  resolveRuntime,
  pruneWorkstreams,
  disconnectInfo,
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
  const tabs: any[] = [];
  for (const [sid, rec] of Object.entries(durable)) {
    // The registry key IS the session id, so a live PTY is a direct lookup.
    const live = runtimes.some(([k]) => k === sid);
    // For a disconnected tab whose last resume failed with "no conversation found",
    // surface the reason and the variant `session doctor` reported (the button gates
    // on doctor's kind, not this projection's rec.kind).
    const info = !live ? disconnectInfo.get(sid) : undefined;
    tabs.push({
      sessionId: sid,
      name: rec.name,
      createdAt: rec.created_at,
      kind: rec.kind,
      connected: live,
      lock: rec.lock ? { holder: rec.lock.holder, mine: rec.lock.holder === HOLDER } : null,
      disconnectReason: info?.reason,
      doctorKind: info?.doctorKind,
    });
  }
  // A live PTY with no durable session record: either an agent session in the tiny
  // window between spawn and `session create` landing, or an ephemeral "shell"
  // (which never gets a record) for as long as its PTY runs. Surface it as a
  // transient tab, rendered from the registry entry's kind.
  for (const [key, s] of runtimes) {
    if (durable[key]) continue;
    const isShell = s.kind === "shell";
    tabs.push({
      sessionId: key,
      name: isShell ? "shell" : "claude",
      createdAt: ws.created_at,
      kind: s.kind ?? "claude-code",
      connected: true,
      lock: null,
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

// Record a freshly-spawned session durably in silverwood (name "claude") and
// acquire its advisory lock for this instance. papyrus mints the id and passes it
// to `claude --session-id`, so this replaces what the plugin hook used to do —
// no runtime callback. Best-effort: a failure is logged, not fatal (the live PTY
// still runs; buildNode surfaces it as a transient tab until the record lands).
async function recordFreshSession(
  wsId: string,
  sessionId: string,
  session: Session,
): Promise<void> {
  try {
    await sw.sessionCreate(wsId, sessionId, "claude");
    await sw.sessionLock(wsId, sessionId, HOLDER);
    session.holdsLock = true;
  } catch (e: any) {
    logError(`\x1b[38;5;141m[session-register]\x1b[0m ${sessionId}: ${e.message}`);
  }
}

// Create a node = create a silverwood workstream (clones its checkout), then spawn
// its Claude Code terminal. Blocks on the clone; the node comes up ready.
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
  let initialSessionId: string | undefined;
  if (sw.checkoutState(ws) === "ready" && cwd) {
    initialSessionId = randomUUID();
    const session = spawnTerminal({
      sessionKey: initialSessionId,
      workstreamId: ws.id,
      cwd,
      resume: false,
    });
    await recordFreshSession(ws.id, initialSessionId, session);
  }

  return c.json({
    sessionId: ws.id,
    nodeId: ws.id,
    cwd,
    checkoutState: sw.checkoutState(ws),
    initialSessionId,
  });
});

// Connect (resume) an existing session: acquire its advisory lock, then spawn a
// `claude --resume <id>` PTY in the checkout. `force` steals a lock held elsewhere.
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

  // Acquire the advisory lock. A contention failure → 409 so the UI can offer
  // Force; any other silverwood error is logged and ignored (the lock is advisory,
  // so it must never block a connect on its own).
  let holdsLock = false;
  try {
    await sw.sessionLock(wsId, sessionId, HOLDER, !!force);
    holdsLock = true;
  } catch (e: any) {
    const m = /is locked by (.+)$/.exec((e.message || "").trim());
    if (m) return c.json({ error: e.message, locked: true, holder: m[1] }, 409);
    log(`\x1b[38;5;141m[lock]\x1b[0m acquire ${sessionId}: ${e.message}`);
  }

  const session = spawnTerminal({
    sessionKey: sessionId,
    workstreamId: wsId,
    cwd,
    resume: true,
  });
  session.holdsLock = holdsLock;
  log(`\x1b[38;5;141m[session]\x1b[0m connected ${sessionId}`);
  return c.json({ sessionId, connected: true });
});

// Add a fresh session tab of the requested `variant` (body `{ variant }`, default
// "claude-code" — an empty/absent body keeps the old behavior). papyrus mints the id.
//  - "claude-code": spawn `claude --session-id <id>` and record the durable
//    silverwood session + advisory lock immediately (no hook).
//  - "shell": spawn an ephemeral `silverwood spawn <ws>` login shell — no durable
//    record, no lock. It lives only while its PTY runs (buildNode surfaces it as a
//    transient tab); it vanishes on exit/disconnect.
apiRoutes.post("/sessions/:wsId/sessions", async (c) => {
  const wsId = c.req.param("wsId");
  const body = await c.req.json().catch(() => ({}));
  const variant = body.variant === "shell" ? "shell" : "claude-code";
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
  const session = spawnTerminal({
    sessionKey: sessionId,
    workstreamId: wsId,
    cwd,
    resume: false,
    kind: variant,
  });
  if (variant === "claude-code") await recordFreshSession(wsId, sessionId, session);
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

// Doctor a session, then delete it if it's an orphan. This backs the disconnected
// screen's "Delete this claude session if it doesn't exist" button: it runs the
// read-only `silverwood session doctor` and, only when a checked variant reports no
// conversation on disk (`conversation_exists === false`), removes the durable session
// via `session rm`. A `true` (real history) or `null` (unknown variant) is left alone.
apiRoutes.post("/sessions/:wsId/sessions/:sessionId/doctor", async (c) => {
  const wsId = c.req.param("wsId");
  const sessionId = c.req.param("sessionId");
  try {
    const report = await sw.sessionDoctor(wsId, sessionId);
    let removed = false;
    if (report.conversation_exists === false) {
      await sw.sessionRemove(wsId, sessionId);
      removed = true;
      log(`\x1b[38;5;141m[doctor]\x1b[0m removed orphaned ${sessionId}`);
    }
    disconnectInfo.delete(sessionId);
    return c.json({
      kind: report.kind,
      conversationExists: report.conversation_exists,
      removed,
    });
  } catch (e: any) {
    logError(`\x1b[38;5;141m[doctor]\x1b[0m ${sessionId}: ${e.message}`);
    return c.json({ error: e.message }, 500);
  }
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
