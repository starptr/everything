// Strip the terminal-query sequences that make an emulator *reply* to the PTY, used only on
// the reconnect scrollback replay (server/index.ts). Replaying raw history to a freshly-built
// emulator makes it re-answer the shell's original startup queries (DA1, OSC 11 ?, …); those
// answers land at the now-idle prompt and echo as garbage like `^[]11;rgb:fafa/fafa/fafa^[\`.
// Live output is never passed through this — only stale, already-answered history — so removing
// these is safe, and a missed variant only risks a rare stray echo, never a hang (the first
// attach replays verbatim so a program still waiting on a query answer is unaffected).

// Each regex matches one response-eliciting request. Kept narrow (query forms only) so real
// output — SGR, cursor motion, OSC color *sets* (no `?`) — survives untouched.
const QUERY_SEQUENCES: RegExp[] = [
  // Primary Device Attributes (DA1): ESC [ c / ESC [ 0 c
  /\x1b\[[0-9;]*c/g,
  // Secondary/Tertiary Device Attributes (DA2/DA3): ESC [ > … c / ESC [ = … c
  /\x1b\[[>=][0-9;]*c/g,
  // Device Status Report (DSR): ESC [ 5 n / ESC [ 6 n / ESC [ ? … n
  /\x1b\[\??[0-9;]*n/g,
  // OSC color queries (the `?` form only): ESC ] <ps> ; ? (BEL | ST)
  /\x1b\][0-9;]*;\?(?:\x07|\x1b\\)/g,
  // DECRQM (request mode): ESC [ ? … $ p
  /\x1b\[\?[0-9;]*\$p/g,
  // XTVERSION: ESC [ > … q
  /\x1b\[>[0-9]*q/g,
];

// Remove response-eliciting query sequences from a chunk of already-emitted terminal output.
export function stripQueries(data: string): string {
  return QUERY_SEQUENCES.reduce((s, re) => s.replace(re, ""), data);
}
