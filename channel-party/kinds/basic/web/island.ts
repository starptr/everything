// `basic` island, serving both roles for type_id "basic" (channel and item share the string).
//   - channel: `mount` renders a live, newest-at-bottom message list — fetch this channel's contents,
//     render each item through *its own* item island (via the registry), then reflect the SSE change
//     stream in place.
//   - item: `renderItem` renders one message.
// The channel delegating to `renderItem` through the registry (rather than rendering items directly)
// is the recursive rendering of DESIGN §9 — for basic it resolves to this same module, but the path
// is generic. The registry sits two levels up from the copied kind dir (generated/kinds/basic/).
import { islands, type IslandModule, type ItemNode } from '../../island-registry';

const PAGE = 50;

type NodePage = { nodes: ItemNode[]; next: string | null };
type Change = { op: 'created' | 'updated' | 'deleted'; super_type: string; id: string };

/** Render one basic message (item-island role). */
export function renderItem(item: ItemNode): HTMLElement {
  const li = document.createElement('li');
  li.className = 'cp-msg';
  li.dataset.itemId = item.id;
  const payload = item.payload as { body?: unknown };
  li.textContent =
    typeof payload?.body === 'string' ? payload.body : JSON.stringify(item.payload);
  return li;
}

/** Mount the basic channel as a live message list (channel-island role). */
export async function mount(el: HTMLElement, ctx: { id: string; type_id: string }): Promise<void> {
  const list = document.createElement('ul');
  list.className = 'cp-msglist';
  const status = document.createElement('p');
  status.className = 'cp-status';

  // Compose box: post a message as the current user. The server gates it (§18) — a signed-out or
  // unauthorized attempt comes back 401/403; a successful post renders via the SSE stream below, so
  // there is no optimistic append here.
  const form = document.createElement('form');
  form.className = 'cp-compose';
  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Message';
  input.required = true;
  const send = document.createElement('button');
  send.type = 'submit';
  send.textContent = 'Send';
  form.append(input, send);
  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    const body = input.value.trim();
    if (body) void post(body);
  });
  el.replaceChildren(list, form, status);

  async function post(body: string): Promise<void> {
    send.disabled = true;
    try {
      const res = await fetch(`/api/channels/${encodeURIComponent(ctx.id)}/items`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ type_id: 'basic', payload: { body } }),
      });
      if (res.ok) {
        input.value = '';
      } else if (res.status === 401) {
        status.textContent = 'Log in to post.';
      } else if (res.status === 403) {
        status.textContent = "You don't have permission to post here.";
      } else {
        status.textContent = `Couldn't send (HTTP ${res.status}).`;
      }
    } catch (err) {
      status.textContent = `Couldn't send: ${String(err)}`;
    } finally {
      send.disabled = false;
    }
  }

  // Load each item type's island once; delegate rendering to it.
  const loaded = new Map<string, IslandModule>();
  async function renderNode(item: ItemNode): Promise<HTMLElement | null> {
    if (!loaded.has(item.type_id)) {
      const load = islands.get(item.type_id);
      if (load) loaded.set(item.type_id, await load());
    }
    const island = loaded.get(item.type_id);
    return island?.renderItem ? island.renderItem(item) : null;
  }

  // Initial page. basic::contents returns { nodes, next } newest-first; reverse for top-to-bottom
  // reading (oldest at top, newest at bottom, chat-style).
  try {
    const res = await fetch(`/api/channels/${encodeURIComponent(ctx.id)}/contents`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ limit: PAGE }),
    });
    if (!res.ok) {
      status.textContent = `Couldn't load messages (HTTP ${res.status}).`;
      return;
    }
    const page = (await res.json()) as NodePage;
    for (const item of [...page.nodes].reverse()) {
      const node = await renderNode(item);
      if (node) list.append(node);
    }
    status.textContent = page.nodes.length ? '' : 'No messages yet.';
  } catch (err) {
    status.textContent = `Couldn't load messages: ${String(err)}`;
    return;
  }

  // Live updates: reflect this channel's change stream in place.
  const events = new EventSource(`/api/events?scope=${encodeURIComponent(ctx.id)}`);
  events.addEventListener('change', (ev) => {
    void applyChange(JSON.parse((ev as MessageEvent).data) as Change);
  });

  async function applyChange(change: Change): Promise<void> {
    if (change.super_type !== 'item') return;
    const existing = list.querySelector<HTMLElement>(`[data-item-id="${change.id}"]`);
    if (change.op === 'deleted') {
      existing?.remove();
      return;
    }
    // created / updated: the event carries no payload, so fetch the item envelope and (re)render it.
    const res = await fetch(`/api/items/${encodeURIComponent(change.id)}`);
    if (!res.ok) return;
    const node = await renderNode((await res.json()) as ItemNode);
    if (!node) return;
    if (existing) {
      existing.replaceWith(node);
    } else {
      list.append(node); // newest at the bottom
      status.textContent = '';
    }
  }
}
