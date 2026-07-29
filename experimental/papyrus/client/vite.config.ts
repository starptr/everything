import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Ports are env-configurable so a dev instance can run alongside a packaged `papyrus`
// (which uses 6968/6969) without colliding: PORT is the backend to proxy to (matches
// server/config.ts), CLIENT_PORT is Vite's own listen port. Defaults keep the originals.
const serverPort = Number(process.env.PORT) || 6968;
const clientPort = Number(process.env.CLIENT_PORT) || 6969;

// Only `/api` is proxied. The terminal WebSocket is NOT: Vite's ws proxy does not relay
// frames to a Bun.serve target (blank panes), so the client connects the terminal ws
// directly to the backend port (from /api/config) — see components/terminalWs.ts.
export default defineConfig({
  plugins: [react()],
  // The libghostty backend (ghostty-web) is a lazy dynamic import, so Vite would only
  // discover it mid-session on first use — re-optimize and full-page reload, which remounts
  // the live terminal in a churn storm. Pre-bundle it here so it's ready at startup. This is
  // a dev-only concern; the production build still code-splits it into its own lazy chunk.
  optimizeDeps: {
    include: ["ghostty-web"],
  },
  server: {
    port: clientPort,
    proxy: {
      "/api": {
        target: `http://localhost:${serverPort}`,
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: "dist",
  },
});
