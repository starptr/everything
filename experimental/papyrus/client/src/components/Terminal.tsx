import { useEffect, useRef } from "react";
import { Terminal as XTerm, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { useStore } from "../stores/useStore";
import { terminalWsUrl } from "./terminalWs";
import { THEMES, type ThemeName } from "../theme";

interface TerminalProps {
  sessionId: string;
  color: string;
}

// xterm needs concrete color strings (not CSS vars), so we keep one ANSI palette per
// polarity and pick by the active theme. `cursor` is the node's accent color.
const DARK_PALETTE: ITheme = {
  background: "#0d0d0d",
  foreground: "#d4d4d4",
  selectionBackground: "#3b3b3b",
  selectionForeground: "#ffffff",
  black: "#1a1a1a",
  red: "#f87171",
  green: "#4ade80",
  yellow: "#fbbf24",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#d4d4d4",
  brightBlack: "#525252",
  brightRed: "#fca5a5",
  brightGreen: "#86efac",
  brightYellow: "#fcd34d",
  brightBlue: "#93c5fd",
  brightMagenta: "#d8b4fe",
  brightCyan: "#67e8f9",
  brightWhite: "#ffffff",
};

const LIGHT_PALETTE: ITheme = {
  background: "#fafafa",
  foreground: "#24292e",
  selectionBackground: "#cfe0f4",
  black: "#24292e",
  red: "#d73a49",
  green: "#22863a",
  yellow: "#b08800",
  blue: "#0366d6",
  magenta: "#6f42c1",
  cyan: "#1b7c83",
  white: "#6a737d",
  brightBlack: "#959da5",
  brightRed: "#cb2431",
  brightGreen: "#28a745",
  brightYellow: "#b08800",
  brightBlue: "#005cc5",
  brightMagenta: "#5a32a3",
  brightCyan: "#3192aa",
  brightWhite: "#24292e",
};

function terminalTheme(themeName: ThemeName, cursorColor: string): ITheme {
  const base = (THEMES[themeName]?.polarity ?? "dark") === "light" ? LIGHT_PALETTE : DARK_PALETTE;
  return { ...base, cursor: cursorColor, cursorAccent: base.background };
}

export function Terminal({ sessionId, color }: TerminalProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<XTerm | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const mountedRef = useRef(false);
  const serverPort = useStore((s) => s.serverPort);
  const resolvedTheme = useStore((s) => s.resolvedTheme);

  useEffect(() => {
    if (!terminalRef.current || !sessionId) return;

    // Prevent double mount in strict mode
    if (mountedRef.current) return;
    mountedRef.current = true;

    // Clear container completely
    while (terminalRef.current.firstChild) {
      terminalRef.current.removeChild(terminalRef.current.firstChild);
    }

    // Create terminal
    const term = new XTerm({
      cursorBlink: true,
      cursorStyle: "bar",
      fontSize: 12,
      fontFamily: '"JetBrains Mono", "Fira Code", "SF Mono", Menlo, monospace',
      fontWeight: "400",
      lineHeight: 1.4,
      letterSpacing: 0,
      // Read the theme non-reactively so a theme switch updates the live terminal
      // (separate effect below) instead of tearing it down and reconnecting.
      theme: terminalTheme(useStore.getState().resolvedTheme, color),
      allowProposedApi: true,
      scrollback: 10000,
    });

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();
    term.loadAddon(fitAddon);
    term.loadAddon(webLinksAddon);

    term.open(terminalRef.current);
    
    // Reset all terminal attributes before receiving buffered content
    term.write("\x1b[0m\x1b[?25h");
    
    setTimeout(() => fitAddon.fit(), 50);

    xtermRef.current = term;
    fitAddonRef.current = fitAddon;

    // Connect WebSocket with small delay to allow session to be ready. Target the
    // backend port directly (from /api/config) so dev bypasses Vite's WS proxy, which
    // does not relay frames; falls back to the page origin (prod = same port).
    const wsUrl = terminalWsUrl(window.location, serverPort, sessionId);

    let ws: WebSocket | null = null;
    let isFirstMessage = true;

    const connectWs = () => {
      if (!mountedRef.current) return;

      ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        if (xtermRef.current) {
          ws?.send(JSON.stringify({ type: "resize", cols: xtermRef.current.cols, rows: xtermRef.current.rows }));
        }
      };

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === "output") {
            // On first message (buffered history), reset terminal state first
            if (isFirstMessage) {
              isFirstMessage = false;
              // Clear screen, reset attributes, move cursor home
              term.write("\x1b[2J\x1b[H\x1b[0m");
            }
            term.write(msg.data);
          }
        } catch (e) {
          term.write(event.data);
        }
      };

      ws.onerror = () => {
        // Silently handle errors - don't spam the terminal
      };

      ws.onclose = () => {
        // Only show if not intentionally closed
      };
    };

    // Small delay to let server session be ready
    const connectTimeout = setTimeout(connectWs, 100);

    term.onData((data) => {
      if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "input", data }));
      }
    });

    const resizeObserver = new ResizeObserver(() => {
      requestAnimationFrame(() => {
        if (fitAddonRef.current) {
          fitAddonRef.current.fit();
        }
        if (ws?.readyState === WebSocket.OPEN && xtermRef.current) {
          ws.send(JSON.stringify({
            type: "resize",
            cols: xtermRef.current.cols,
            rows: xtermRef.current.rows
          }));
        }
      });
    });

    resizeObserver.observe(terminalRef.current);

    return () => {
      mountedRef.current = false;
      clearTimeout(connectTimeout);
      resizeObserver.disconnect();
      ws?.close();
      term.dispose();
    };
  }, [sessionId, color, serverPort]);

  // Re-theme the live terminal when the app theme (or node color) changes, without
  // recreating it — keeps scrollback and the WebSocket intact.
  useEffect(() => {
    const term = xtermRef.current;
    if (term) term.options.theme = terminalTheme(resolvedTheme, color);
  }, [resolvedTheme, color]);

  return (
    <div
      ref={terminalRef}
      className="w-full h-full"
      style={{
        padding: "12px",
        backgroundColor: "rgb(var(--color-terminal-bg))",
        minHeight: "200px"
      }}
    />
  );
}
