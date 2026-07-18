import { Hono } from "hono";
import { cors } from "hono/cors";
import { serveStatic } from "hono/bun";
import type { ServerWebSocket } from "bun";
import { apiRoutes } from "./routes/api";
import { sessions, resolveRuntime, HOLDER } from "./services/sessionManager";
import * as sw from "./services/silverwood";
import { PORT } from "./config";
import type { WebSocketData } from "./types";

const app = new Hono();
const QUIET = !!process.env.OPENUI_QUIET;

// Conditionally log only in dev mode
const log = QUIET ? () => {} : console.log.bind(console);

// Middleware
app.use("*", cors());

// API Routes
app.route("/api", apiRoutes);

// Serve static files
app.use("/*", serveStatic({ root: "./client/dist" }));

// WebSocket server
Bun.serve<WebSocketData>({
  port: PORT,
  fetch(req, server) {
    const url = new URL(req.url);

    if (url.pathname === "/ws") {
      const sessionId = url.searchParams.get("sessionId");
      if (!sessionId) return new Response("Session ID required", { status: 400 });

      const r = resolveRuntime(sessionId);
      if (!r) return new Response("Session not found", { status: 404 });

      // Key the socket by the resolved registry key (a fresh session is addressed
      // by a provisional id but registered under it).
      const upgraded = server.upgrade(req, { data: { sessionId: r[0] } });
      if (upgraded) return undefined;
      return new Response("WebSocket upgrade failed", { status: 400 });
    }

    return app.fetch(req);
  },
  websocket: {
    open(ws) {
      const { sessionId } = ws.data;
      const session = sessions.get(sessionId);

      if (!session) {
        ws.close(1008, "Session not found");
        return;
      }

      log(`\x1b[38;5;245m[ws]\x1b[0m Connected to ${sessionId}`);
      session.clients.add(ws);

      // Replay scrollback so a (re)connecting client sees the live terminal.
      if (session.outputBuffer.length > 0) {
        ws.send(JSON.stringify({ type: "output", data: session.outputBuffer.join("") }));
      }

      ws.send(JSON.stringify({ type: "status", status: session.status }));
    },
    message(ws, message) {
      const { sessionId } = ws.data;
      const session = sessions.get(sessionId);
      if (!session) return;

      try {
        const msg = JSON.parse(message.toString());
        switch (msg.type) {
          case "input":
            if (session.pty) {
              session.pty.write(msg.data);
              session.lastInputTime = Date.now();
            }
            break;
          case "resize":
            if (session.pty) {
              session.pty.resize(msg.cols, msg.rows);
            }
            break;
        }
      } catch (e) {
        if (!QUIET) console.error("Error processing message:", e);
      }
    },
    close(ws) {
      const { sessionId } = ws.data;
      const session = sessions.get(sessionId);
      if (session) {
        session.clients.delete(ws);
        log(`\x1b[38;5;245m[ws]\x1b[0m Disconnected from ${sessionId}`);
      }
    },
  },
});

log(`\x1b[38;5;141m[server]\x1b[0m Running on http://localhost:${PORT}`);
log(`\x1b[38;5;245m[server]\x1b[0m Launch directory: ${process.env.LAUNCH_CWD || process.cwd()}`);
log(`\x1b[38;5;245m[server]\x1b[0m Forest: ${process.env.SILVERWOOD_FOREST_PATH || "~/.silverwood"}`);

// The canvas is rebuilt from silverwood on demand (GET /api/state); there is no
// startup restore and nothing to autosave — all durable state lives in silverwood.

// Cleanup on exit: release advisory locks this instance holds (best-effort), then
// kill terminals. A hard crash skips this; a stuck lock is recovered via a force-steal.
process.on("SIGINT", async () => {
  const held = [...sessions.values()].filter((s) => s.holdsLock && s.claudeSessionId);
  await Promise.allSettled(
    held.map((s) => sw.sessionUnlock(s.workstreamId, s.claudeSessionId!, HOLDER)),
  );
  for (const [, session] of sessions) session.pty.kill();
  process.exit(0);
});
