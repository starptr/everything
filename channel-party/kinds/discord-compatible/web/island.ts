// `discord-compatible` island — one module for all four channel kinds, branching on `ctx.type_id`
// (DESIGN §5/§9, design/discord.md):
//   - guild / section (structural): render the channel subtree as links the type-agnostic shell opens
//     (recursive discovery — opening one mounts its own island).
//   - channel / forum (leaf): render the ingested cached-message feed.
// Contents comes from this channel's own `contents` (guild → `descendants`, channel → `children`).

type ChannelNode = {
  super_type: 'channel';
  id: string;
  type_id: string;
  container: string | null;
  payload: { discord_id?: string; name?: string };
};
type ItemNode = {
  super_type: 'item';
  id: string;
  type_id: string;
  payload: { author_name?: string; content?: string };
};
type NodePage = { nodes: Array<ChannelNode | ItemNode>; next: string | null };

const STRUCTURAL = new Set(['discord-compatible/guild', 'discord-compatible/section']);

async function fetchContents(id: string): Promise<NodePage | null> {
  const res = await fetch(`/api/channels/${encodeURIComponent(id)}/contents`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({}),
  });
  return res.ok ? ((await res.json()) as NodePage) : null;
}

function channelLink(node: ChannelNode): HTMLElement {
  const li = document.createElement('li');
  li.className = 'cp-msg';
  const a = document.createElement('a');
  a.href = `/channels/${encodeURIComponent(node.id)}`;
  a.textContent = node.payload.name ?? `#${node.payload.discord_id ?? node.id}`;
  li.append(a);
  return li;
}

function messageLine(node: ItemNode): HTMLElement {
  const li = document.createElement('li');
  li.className = 'cp-msg';
  li.textContent = `${node.payload.author_name ?? 'unknown'}: ${node.payload.content ?? ''}`;
  return li;
}

/** Mount a discord channel: a tree of links (structural) or a message feed (leaf). */
export async function mount(el: HTMLElement, ctx: { id: string; type_id: string }): Promise<void> {
  const list = document.createElement('ul');
  list.className = 'cp-msglist';
  const status = document.createElement('p');
  status.className = 'cp-status';
  el.replaceChildren(list, status);

  const page = await fetchContents(ctx.id);
  if (!page) {
    status.textContent = 'Could not load this channel.';
    return;
  }

  const structural = STRUCTURAL.has(ctx.type_id);
  // Leaf feeds arrive newest-first; show oldest-at-top, chat-style.
  const nodes = structural ? page.nodes : [...page.nodes].reverse();
  for (const node of nodes) {
    if (structural && node.super_type === 'channel') {
      list.append(channelLink(node));
    } else if (node.super_type === 'item') {
      list.append(messageLine(node));
    }
  }
  status.textContent = page.nodes.length ? '' : structural ? 'No channels yet.' : 'No messages yet.';
}
