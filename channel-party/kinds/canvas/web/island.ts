// `canvas` island, serving both roles for the canvas slice.
//   - channel: `mount` renders a pannable viewport — it POSTs the visible rectangle to `contents`
//     (which runs the R-tree bbox query), draws each box through *its own* item island via the
//     registry (the §9 recursive-render path), re-queries when a pan settles, and reflects the SSE
//     change stream in place.
//   - item: `renderItem` draws one text box, absolutely positioned in the canvas plane.
// See DESIGN §9 and `design/runtime.md`.
import { islands, type IslandModule, type ItemNode } from '../../island-registry';

type NodePage = { nodes: ItemNode[]; next: string | null };
type BoxPayload = { x?: unknown; y?: unknown; w?: unknown; h?: unknown; text?: unknown };

/** A finite number from unknown JSON, else a default. */
function num(v: unknown, d = 0): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : d;
}

/** Draw one canvas-text-box, absolutely positioned in the plane (item-island role). */
export function renderItem(item: ItemNode): HTMLElement {
  const p = (item.payload ?? {}) as BoxPayload;
  const el = document.createElement('div');
  el.dataset.itemId = item.id;
  Object.assign(el.style, {
    position: 'absolute',
    left: `${num(p.x)}px`,
    top: `${num(p.y)}px`,
    width: `${num(p.w, 80)}px`,
    height: `${num(p.h, 40)}px`,
    border: '1px solid #888',
    background: '#fff',
    color: '#111',
    padding: '4px',
    boxSizing: 'border-box',
    overflow: 'hidden',
    font: '12px system-ui, sans-serif',
  });
  el.textContent = typeof p.text === 'string' ? p.text : '';
  return el;
}

/** Mount the canvas as a pannable viewport (channel-island role). */
export async function mount(el: HTMLElement, ctx: { id: string; type_id: string }): Promise<void> {
  const status = document.createElement('p');
  status.className = 'cp-status';
  const plane = document.createElement('div');
  Object.assign(el.style, {
    position: 'relative',
    overflow: 'hidden',
    height: '70vh',
    border: '1px solid #ddd',
    cursor: 'grab',
    touchAction: 'none',
  });
  Object.assign(plane.style, { position: 'absolute', top: '0', left: '0' });
  el.replaceChildren(status, plane);

  let panX = 0;
  let panY = 0;

  // Delegate box drawing to the registered item island (recursive render, §9).
  const loaded = new Map<string, IslandModule>();
  async function draw(node: ItemNode): Promise<HTMLElement | null> {
    if (!loaded.has(node.type_id)) {
      const load = islands.get(node.type_id);
      if (load) loaded.set(node.type_id, await load());
    }
    return loaded.get(node.type_id)?.renderItem?.(node) ?? null;
  }

  function applyPan(): void {
    plane.style.transform = `translate(${panX}px, ${panY}px)`;
  }

  // The visible canvas rectangle (plus a margin so boxes near the edge preload).
  function viewport(): { x0: number; y0: number; x1: number; y1: number } {
    const r = el.getBoundingClientRect();
    const m = 200;
    return { x0: -panX - m, y0: -panY - m, x1: -panX + r.width + m, y1: -panY + r.height + m };
  }

  async function reload(): Promise<void> {
    try {
      const res = await fetch(`/api/channels/${encodeURIComponent(ctx.id)}/contents`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(viewport()),
      });
      if (!res.ok) {
        status.textContent = `Couldn't load canvas (HTTP ${res.status}).`;
        return;
      }
      const page = (await res.json()) as NodePage;
      const boxes = await Promise.all(page.nodes.map(draw));
      plane.replaceChildren(...boxes.filter((b): b is HTMLElement => b !== null));
      status.textContent = page.nodes.length ? '' : 'Empty canvas — drag to pan.';
    } catch (err) {
      status.textContent = `Couldn't load canvas: ${String(err)}`;
    }
  }

  applyPan();
  await reload();

  // Drag to pan; re-query the viewport once the drag settles.
  let dragging = false;
  let startX = 0;
  let startY = 0;
  let baseX = 0;
  let baseY = 0;
  el.addEventListener('pointerdown', (e) => {
    dragging = true;
    startX = e.clientX;
    startY = e.clientY;
    baseX = panX;
    baseY = panY;
    el.setPointerCapture(e.pointerId);
  });
  el.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    panX = baseX + (e.clientX - startX);
    panY = baseY + (e.clientY - startY);
    applyPan();
  });
  el.addEventListener('pointerup', (e) => {
    if (!dragging) return;
    dragging = false;
    el.releasePointerCapture(e.pointerId);
    void reload();
  });

  // Live updates: a box create/move/delete re-queries the current viewport in place.
  const events = new EventSource(`/api/events?scope=${encodeURIComponent(ctx.id)}`);
  events.addEventListener('change', () => void reload());
}
