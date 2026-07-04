// `canvas` island: a pan/zoom canvas that owns placement and delegates drawing each box to the
// `canvas-text-box` item island via the same registry. Scaffold placeholder. See DESIGN §9.
export function mount(el: HTMLElement, ctx: { id: string; type_id: string }): void {
  el.textContent = `[${ctx.type_id}] pan/zoom canvas island for channel ${ctx.id} — not yet implemented`;
}
