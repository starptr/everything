import { useEffect, useRef } from "react";
import { useStore } from "../stores/useStore";
import { terminalWsUrl } from "./terminalWs";
import { createTerminalBackend, type TerminalBackend } from "../terminal/backend";
import { terminalTheme } from "../terminal/palette";

interface TerminalProps {
  sessionId: string;
  color: string;
}

export function Terminal({ sessionId, color }: TerminalProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const backendRef = useRef<TerminalBackend | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const serverPort = useStore((s) => s.serverPort);
  const resolvedTheme = useStore((s) => s.resolvedTheme);
  const lineSpacing = useStore((s) => s.lineSpacing);
  const backendId = useStore((s) => s.terminalBackend);

  // Backends that can't mutate theme/line-height live (ghostty) fold those into a remount
  // token, so changing either rebuilds the pane at the right settings. xterm applies both
  // live, so its token is constant and its rebuild triggers stay exactly the old deps.
  const remountToken = backendId === "xterm" ? "" : `${resolvedTheme}:${lineSpacing}`;

  useEffect(() => {
    const container = terminalRef.current;
    if (!container || !sessionId) return;

    // Each effect run owns its own `cancelled` flag; the async body checks it after every
    // await so a StrictMode double-mount (or a rapid dep change) disposes the just-built
    // backend instead of leaking a second terminal + WebSocket.
    let cancelled = false;
    let backend: TerminalBackend | null = null;
    let ws: WebSocket | null = null;
    let resizeObserver: ResizeObserver | null = null;
    let connectTimeout: ReturnType<typeof setTimeout> | undefined;
    let fitTimeout: ReturnType<typeof setTimeout> | undefined;

    // Clear the container completely before (re)mounting a terminal.
    while (container.firstChild) container.removeChild(container.firstChild);

    (async () => {
      const created = await createTerminalBackend(backendId, {
        cursorBlink: true,
        cursorStyle: "bar",
        fontSize: 12,
        fontFamily: '"JetBrains Mono", "Fira Code", "SF Mono", Menlo, monospace',
        fontWeight: "400",
        letterSpacing: 0,
        scrollback: 10000,
        allowProposedApi: true,
        // Read non-reactively; live changes are handled by the effects below (xterm) or the
        // remount token (ghostty), not by tearing down here.
        lineHeight: useStore.getState().lineSpacing,
        theme: terminalTheme(useStore.getState().resolvedTheme, color),
      }).catch((err) => {
        console.warn("[papyrus] terminal backend init failed", err);
        return null;
      });

      // Torn down while awaiting the backend (StrictMode / rapid dep change) → bail.
      if (cancelled || !created) {
        created?.dispose();
        return;
      }
      backend = created;
      backendRef.current = created;

      backend.open(container);
      // Reset all terminal attributes and show the cursor before buffered content arrives.
      backend.write("\x1b[0m\x1b[?25h");
      fitTimeout = setTimeout(() => {
        if (!cancelled) backend?.fit();
      }, 50);

      // Connect straight to the backend port (from /api/config) so dev bypasses Vite's WS
      // proxy, which does not relay frames; falls back to the page origin (prod = same port).
      const wsUrl = terminalWsUrl(window.location, serverPort, sessionId);
      let isFirstMessage = true;

      const connectWs = () => {
        if (cancelled) return;

        ws = new WebSocket(wsUrl);
        wsRef.current = ws;

        ws.onopen = () => {
          const size = backend?.size;
          if (size) ws?.send(JSON.stringify({ type: "resize", cols: size.cols, rows: size.rows }));
        };

        ws.onmessage = (event) => {
          try {
            const msg = JSON.parse(event.data);
            if (msg.type === "output") {
              // The first message is buffered history: reset terminal state first.
              if (isFirstMessage) {
                isFirstMessage = false;
                backend?.write("\x1b[2J\x1b[H\x1b[0m");
              }
              backend?.write(msg.data);
            }
          } catch {
            backend?.write(event.data);
          }
        };
      };

      // Small delay to let the server session be ready.
      connectTimeout = setTimeout(connectWs, 100);

      backend.onData((data) => {
        if (ws?.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "input", data }));
        }
      });

      resizeObserver = new ResizeObserver(() => {
        requestAnimationFrame(() => {
          if (cancelled) return;
          backend?.fit();
          const size = backend?.size;
          if (ws?.readyState === WebSocket.OPEN && size) {
            ws.send(JSON.stringify({ type: "resize", cols: size.cols, rows: size.rows }));
          }
        });
      });
      resizeObserver.observe(container);
    })();

    return () => {
      cancelled = true;
      clearTimeout(connectTimeout);
      clearTimeout(fitTimeout);
      resizeObserver?.disconnect();
      ws?.close();
      backend?.dispose();
      backendRef.current = null;
      wsRef.current = null;
    };
  }, [sessionId, color, serverPort, backendId, remountToken]);

  // Re-theme the live terminal when the app theme (or node color) changes, without
  // recreating it — keeps scrollback and the WebSocket intact. Backends that can't
  // re-theme live return false and are handled by the remount token instead.
  useEffect(() => {
    backendRef.current?.setTheme(resolvedTheme, color);
  }, [resolvedTheme, color]);

  // Apply line-spacing changes live. Unlike a re-theme, line height changes the row count,
  // so refit and tell the PTY the new dimensions. Backends without live support return
  // false (the remount token already rebuilt the pane) and this no-ops.
  useEffect(() => {
    const backend = backendRef.current;
    if (backend && backend.setLineHeight(lineSpacing)) {
      backend.fit();
      const ws = wsRef.current;
      const size = backend.size;
      if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "resize", cols: size.cols, rows: size.rows }));
      }
    }
  }, [lineSpacing]);

  return (
    <div
      ref={terminalRef}
      className="w-full h-full"
      style={{
        padding: "12px",
        backgroundColor: "rgb(var(--color-terminal-bg))",
        minHeight: "200px",
      }}
    />
  );
}
