// `basic` channel island: a message list. Owns its own data fetching (POST
// /api/channels/:id/contents with a page query), rendering, and live updates via SSE. Scaffold
// placeholder. See DESIGN §9.
export function mount(el: HTMLElement, ctx: { id: string; type_id: string }): void {
  el.textContent = `[${ctx.type_id}] message-list island for channel ${ctx.id} — not yet implemented`;
}
