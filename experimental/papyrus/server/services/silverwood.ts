// The single persistence boundary: papyrus stores *all* durable state in
// silverwood by shelling out to the `silverwood --json` CLI. There is no local
// disk state — no `.openui/`. A canvas node IS a silverwood workstream; its
// presentation state (position/color/notes) lives in the workstream's KV under
// papyrus's own namespace, and agent runs are recorded as silverwood sessions.

const QUIET = !!process.env.OPENUI_QUIET;
const log = QUIET ? () => {} : console.log.bind(console);

// The `silverwood` binary (on PATH via the Nix wrapper; overridable for dev).
const SILVERWOOD_BIN = process.env.SILVERWOOD_BIN || "silverwood";

// papyrus's own per-workstream KV namespace for canvas presentation state.
// (NOT under silverwood's reserved `app.andref.silverwood.*` prefix.)
export const PAPYRUS_NS = "app.andref.papyrus";

// The basic kind's data-carrying checkout mode (silverwood schema v3): it owns the
// materialization strategy's seed (`initial_source`) and its provisioning `state`.
export interface CheckoutMode {
  checkout_mode: string;
  initial_source: string;
  state: "pending" | "ready" | "failed";
}

// Where the checkout physically lives: which forest, and (per forest kind) where.
export interface Location {
  forest_id: string;
  within: { forest_kind: string; path: string };
}

export interface Workstream {
  id: string;
  name: string;
  status: "active" | "archived";
  created_at: string;
  kind: string;
  mode?: CheckoutMode;
  location?: Location;
  kv?: Record<string, Record<string, string>>;
}

export interface AgentSession {
  kind: string;
  name: string;
  created_at: string;
}

/// Run `silverwood --json <args>` and parse its stdout. Async (never blocks the
/// event loop) so a slow `new` clone does not freeze the server. Throws on a
/// non-zero exit, surfacing silverwood's stderr.
async function run(args: string[]): Promise<any> {
  const proc = Bun.spawn([SILVERWOOD_BIN, "--json", ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    throw new Error(
      `silverwood ${args.join(" ")} failed: ${stderr.trim() || `exit ${exitCode}`}`,
    );
  }
  const out = stdout.trim();
  return out ? JSON.parse(out) : null;
}

// ---- reads ----

export function list(includeArchived = false): Promise<Workstream[]> {
  return run(includeArchived ? ["ls", "--all"] : ["ls"]);
}

export function get(id: string): Promise<Workstream> {
  return run(["show", id]);
}

export async function getPapyrusKv(id: string): Promise<Record<string, string>> {
  return (await run(["kv", "ls", id, PAPYRUS_NS])) || {};
}

export async function sessionLs(id: string): Promise<Record<string, AgentSession>> {
  return (await run(["session", "ls", id])) || {};
}

// ---- writes (serialized per workstream — see below) ----

export function create(params: {
  name: string;
  source: string;
  mode?: string;
}): Promise<Workstream> {
  // Blocks on `jj git clone --colocate`; the checkout carries a pending→ready
  // state machine, so the returned workstream is the finished (ready/failed) one.
  return run([
    "new",
    "--name",
    params.name,
    "--source",
    params.source,
    "--mode",
    params.mode || "jj-colocated",
  ]);
}

export function archive(id: string): Promise<void> {
  return serialize(id, () => run(["archive", id]));
}

export function rename(id: string, name: string): Promise<void> {
  return serialize(id, () => run(["rename", id, name]));
}

/// Set a papyrus presentation key. `value` is a JS value; stored JSON-encoded
/// (silverwood KV values are opaque JSON strings).
export function setKv(id: string, key: string, value: unknown): Promise<void> {
  return serialize(id, () =>
    run(["kv", "set", id, PAPYRUS_NS, key, JSON.stringify(value)]),
  );
}

export function unsetKv(id: string, key: string): Promise<void> {
  return serialize(id, () => run(["kv", "unset", id, PAPYRUS_NS, key]));
}

export function sessionCreate(
  id: string,
  sessionId: string,
  name: string,
): Promise<void> {
  return serialize(id, () =>
    run(["session", "create", "claude-code", id, sessionId, "--name", name]),
  );
}

export function sessionRemove(id: string, sessionId: string): Promise<void> {
  return serialize(id, () => run(["session", "rm", id, sessionId]));
}

// silverwood does read-modify-overwrite of the whole document with no file
// locking, so two concurrent writers to the SAME workstream can lose an update.
// Serialize every mutation per workstream id through an in-process promise chain.
// (Different workstreams are independent files and run concurrently.)
const writeQueues = new Map<string, Promise<unknown>>();

function serialize<T>(id: string, fn: () => Promise<T>): Promise<T> {
  const prev = writeQueues.get(id) ?? Promise.resolve();
  const next = prev.then(fn, fn);
  // Keep the chain alive but swallow errors for the *next* waiter's gate.
  writeQueues.set(
    id,
    next.catch(() => {}),
  );
  return next;
}

// ---- helpers ----

/// The checkout location for a workstream (the dir the agent runs in). A basic
/// workstream is single-forest, so there is exactly one location.
export function checkoutLocation(ws: Workstream): string | undefined {
  return ws.location?.within.path || undefined;
}

/// The provisioning state to surface to the canvas (carried by the checkout mode).
export function checkoutState(
  ws: Workstream,
): "ready" | "pending" | "failed" | "none" {
  return ws.mode?.state ?? "none";
}

/// Read a papyrus KV value, JSON-decoded, or `undefined` if absent/garbage.
export function decodeKv<T>(kv: Record<string, string>, key: string): T | undefined {
  const raw = kv[key];
  if (raw === undefined) return undefined;
  try {
    return JSON.parse(raw) as T;
  } catch {
    log(`[silverwood] undecodable papyrus kv ${key}: ${raw}`);
    return undefined;
  }
}
