import { useCallback, useRef, useState } from "react";

// Keep a persisted pane width inside a usable range, and never let a saved value
// overflow the current viewport (window shrank since it was stored).
export function clampWidth(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

interface ResizablePaneOptions {
  storageKey: string;
  defaultWidth: number;
  min: number;
  max: number;
  // Gap kept between the pane's left edge and the viewport's left edge.
  margin?: number;
}

interface GripProps {
  onPointerDown: (e: React.PointerEvent) => void;
  onPointerMove: (e: React.PointerEvent) => void;
  onPointerUp: (e: React.PointerEvent) => void;
  onPointerCancel: (e: React.PointerEvent) => void;
}

// Owns the width of a right-docked pane resized by dragging its LEFT edge.
// Uses pointer capture so the drag keeps tracking outside the thin grip and
// auto-cleans on pointer-up. Persists the chosen width to localStorage.
export function useResizablePane({
  storageKey,
  defaultWidth,
  min,
  max,
  margin = 80,
}: ResizablePaneOptions) {
  const maxForViewport = () => Math.min(max, window.innerWidth - margin);

  const [width, setWidth] = useState<number>(() => {
    const saved = Number(localStorage.getItem(storageKey));
    const initial = Number.isFinite(saved) && saved > 0 ? saved : defaultWidth;
    return clampWidth(initial, min, maxForViewport());
  });
  const [dragging, setDragging] = useState(false);

  const drag = useRef<{ startX: number; startWidth: number } | null>(null);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Don't let React Flow interpret the drag as a canvas pan / selection.
      e.preventDefault();
      e.stopPropagation();
      // Pointer capture keeps the drag tracking outside the thin grip; tolerate
      // environments that don't implement it (older/test DOMs).
      try {
        e.currentTarget.setPointerCapture(e.pointerId);
      } catch {
        /* capture is best-effort */
      }
      drag.current = { startX: e.clientX, startWidth: width };
      setDragging(true);
      document.body.style.userSelect = "none";
      document.body.style.cursor = "col-resize";
    },
    [width]
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!drag.current) return;
      // Left edge: dragging left (clientX decreases) widens the pane.
      const delta = drag.current.startX - e.clientX;
      setWidth(clampWidth(drag.current.startWidth + delta, min, maxForViewport()));
    },
    [min, max, margin]
  );

  const endDrag = useCallback(
    (e: React.PointerEvent) => {
      if (!drag.current) return;
      drag.current = null;
      setDragging(false);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      try {
        if (e.currentTarget.hasPointerCapture?.(e.pointerId)) {
          e.currentTarget.releasePointerCapture(e.pointerId);
        }
      } catch {
        /* capture is best-effort */
      }
      setWidth((w) => {
        localStorage.setItem(storageKey, String(w));
        return w;
      });
    },
    [storageKey]
  );

  const gripProps: GripProps = {
    onPointerDown,
    onPointerMove,
    onPointerUp: endDrag,
    onPointerCancel: endDrag,
  };

  return { width, dragging, gripProps };
}
