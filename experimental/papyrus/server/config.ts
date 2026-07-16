// Single source of truth for the server's listen address. Both the HTTP/WS
// server (server/index.ts) and the PTY spawner (services/sessionManager.ts) read
// these, so the Claude plugin's status hooks are told the port the server is
// ACTUALLY on — see the OPENUI_PORT propagation in spawnTerminal. Keeping these
// in one place is what prevents the plugin/server port drift that silently
// dropped every status POST (plugin default 6969 vs server default 6968).
export const PORT = Number(process.env.PORT) || 6968;
export const HOST = process.env.HOST || "localhost";
