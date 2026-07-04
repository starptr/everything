// `space` channel island: a search UI over descendant channels by name. Scaffold placeholder.
// See DESIGN §9.
export function mount(el: HTMLElement, ctx: { id: string; type_id: string }): void {
  el.textContent = `[${ctx.type_id}] search island for channel ${ctx.id} — not yet implemented`;
}
