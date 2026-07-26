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
