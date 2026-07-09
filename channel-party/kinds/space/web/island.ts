// `space` channel island: a search box over the space's descendant channels by name. Submitting a
// query POSTs it to this channel's `contents` (which runs core's FTS `search`), then lists each match
// as a link the type-agnostic shell opens — recursive discovery (DESIGN §9): opening a result mounts
// *its* island. See `design/index-search.md`.

// One channel reference in a search result — a serialized cp_model::Node::Channel.
type ChannelNode = {
  super_type: 'channel';
  id: string;
  type_id: string;
  container: string | null;
  payload: unknown;
};
type NodePage = { nodes: ChannelNode[]; next: string | null };

// One page of results. The offset cursor (page.next) exists, but the search box shows the first page
// only — finding a channel rarely needs to scroll past this.
const PAGE = 50;

/** The channel's display name, falling back to its id. */
function channelName(node: ChannelNode): string {
  const payload = node.payload as { name?: unknown };
  return typeof payload?.name === 'string' ? payload.name : node.id;
}

/** Mount the space as a channel-search UI (channel-island role). */
export function mount(el: HTMLElement, ctx: { id: string; type_id: string }): void {
  const form = document.createElement('form');
  const input = document.createElement('input');
  input.type = 'search';
  input.placeholder = 'Search channels…';
  input.autofocus = true;
  const button = document.createElement('button');
  button.textContent = 'Search';
  form.append(input, button);

  const status = document.createElement('p');
  status.className = 'cp-status';
  const list = document.createElement('ul');
  list.className = 'cp-msglist';
  el.replaceChildren(form, status, list);

  async function run(q: string): Promise<void> {
    list.replaceChildren();
    // Mirror core's trigram floor (§ search): under 3 chars there is nothing to match.
    if (q.length < 3) {
      status.textContent = q ? 'Type at least 3 characters.' : '';
      return;
    }
    status.textContent = 'Searching…';
    try {
      const res = await fetch(`/api/channels/${encodeURIComponent(ctx.id)}/contents`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ q, limit: PAGE }),
      });
      if (!res.ok) {
        status.textContent = `Search failed (HTTP ${res.status}).`;
        return;
      }
      const page = (await res.json()) as NodePage;
      for (const node of page.nodes) {
        const li = document.createElement('li');
        li.className = 'cp-msg';
        const a = document.createElement('a');
        a.href = `/channels/${encodeURIComponent(node.id)}`;
        a.textContent = channelName(node);
        li.append(a);
        list.append(li);
      }
      status.textContent = page.nodes.length ? '' : `No channels match "${q}".`;
    } catch (err) {
      status.textContent = `Search failed: ${String(err)}`;
    }
  }

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    void run(input.value.trim());
  });
}
