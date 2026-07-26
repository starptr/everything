// The terminal WebSocket URL. When the backend port is known (from /api/config), connect
// straight to it — in dev the page is served by Vite on a different port whose WS proxy
// does not relay frames, so going through the page origin would yield a blank pane. When
// the port is unknown (config not loaded yet), fall back to the page origin; in production
// that IS the backend, so the URL is unchanged.
export function terminalWsUrl(
  loc: { protocol: string; hostname: string; host: string },
  serverPort: number | null,
  sessionId: string,
): string {
  const proto = loc.protocol === "https:" ? "wss:" : "ws:";
  const host = serverPort ? `${loc.hostname}:${serverPort}` : loc.host;
  return `${proto}//${host}/ws?sessionId=${sessionId}`;
}
