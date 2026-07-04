// `discord-compatible` island: a threaded guild/channel view. A guild island renders channel
// references; opening one recursively mounts that child's island. Scaffold placeholder.
// See DESIGN §5/§9.
export function mount(el: HTMLElement, ctx: { id: string; type_id: string }): void {
  el.textContent = `[${ctx.type_id}] threaded view island for channel ${ctx.id} — not yet implemented`;
}
