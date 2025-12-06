# One Night Ultimate Werewolf — Design Doc

## Goals

- Server is the source of truth (authoritative game state, secret info stays server-side).
- Modular role system so adding/changing roles is declarative and low-friction.
- Use `boardgame.io` for authoritative game state, moves, phases, and multiplayer.
- Use `parcel` to produce simple, fast dev builds and minimal config.
- Use best practices for code maintainability.
  - Use TypeScript for strong typing.
  - Use React for client UI.
  - Don't use express; boardgame.io has a built-in Koa server.
  - Don't use extra tools like ts-node; instead, keep it simple: compile with tsc and run with node.
- Clear low-level structure so future contributors can easily edit rules and UI.
- Robust reconnect, lobby, and spectating support.

## Constraints & Decisions

- Language: TypeScript (strong typing helps future edits and role correctness).
- Framework (Client): React (boardgame.io React bindings are well supported).
- Server: boardgame.io’s server or a custom Express server wired to boardgame.io multiplayer.
- Bundler: Parcel (zero-config dev experience).
- Persistence: boardgame.io has in-memory room state; for production, plan for a DB-backed state store (e.g., Redis or Postgres), but do not implement this. For now, only implement in-memory state.
- Secrets: Use boardgame.io’s `playerView` and `secret` mechanics so clients only receive allowed info.

## High-level Architecture

```
[Client (React + boardgame.io client)] <--> [boardgame.io Server / Game Logic (Source of truth)]
```

- Clients are thin: display state, send move requests.
- Server runs the Game (boardgame.io Game object) and enforces rules.
- Role definitions and night-resolution logic live on the server inside modular role modules.
- UI code mirrors role metadata for rendering but does not contain authoritative logic.

## Boardgame.io mapping

- `G` (game state): all public and private state (roles, center cards, swaps, votes, timestamps).
- `ctx` (context): use phases and turns for structuring Night → Day → Vote → Reveal.
- `moves`: player-initiated actions (e.g., `performNightAction`, `castVote`, `pass`).
- `phases`: `lobby`, `night`, `day`, `voting`, `reveal`, `end`.
- `playerView`: Use `playerView`: `PlayerView.STRIP_SECRETS` and custom `playerView` to reveal each player's role card and any private logs.

## Game flow (One Night Ultimate Werewolf game summary)

1. Lobby: players join, pick seats, start game.
2. Deal: server assigns a role card to each player and 3 center cards.
3. Night Phase: roles act — many have private, sequential or simultaneous actions. Server collects actions and applies them deterministically.
4. Day Phase: open discussion (no server logic required beyond timers and permissions).
5. Voting Phase: players cast votes. Votes are recorded in `G.votes`.
6. Reveal / Scoring: server determines winners (e.g. if werewolves are eliminated or not, if special role wins, etc.). Reveal last known role/original role changes per rules.

## Data model (`G`) — suggested TypeScript types (simplified)

```typescript
type PlayerID = string; // "0", "1", "2", ... (boardgame.io style)

type RoleId = string;  // "werewolf", "seer", "robber", etc.

interface RoleDefinition {
  id: RoleId;
  name: string;
  description?: string;
  nightAction?: NightActionSpec; // optional
  onAction?: (G, ctx, actionResult) => void;
  // any other hooks
}

interface PlayerState {
  id: PlayerID;
  seat: number;
  role: RoleId; // current role (may change during night)
  originalRole: RoleId;
  privateLog: string[]; // messages only for the player
}

interface GState {
  players: Record<PlayerID, PlayerState>;
  center: RoleId[]; // 3 center cards
  votes: Record<PlayerID, PlayerID>; // vote from -> vote to
  nightActions: NightActionRecord; // collect actions during night
  revealed: {
    winners: string[]; // list of winner playerIDs
    endSummary: any;
  } | null;
  // metadata for UI: timers, turn index, etc.
}
```

## Role system — Modular + Declarative

Design roles as self-contained modules exporting a small set of hooks and metadata. This keeps behavior discoverable and easy to extend.

### Role module shape

```typescript
// roles/robber.ts
import { RoleDefinition } from "../types";

const Robber: RoleDefinition = {
  id: "robber",
  name: "Robber",
  description: "You may swap your role with another player's and look at your new role.",
  nightAction: {
    // used by night engine to present UI (client) and validate server inputs
    uiPrompt: {
      type: "choosePlayer",
      min: 1, max: 1,
      label: "Choose a player to rob (swap roles)",
    },
    perform: (G, ctx, { actor, target }) => {
      // swap actor.role and target.role
      const actorState = G.players[actor];
      const targetState = G.players[target];
      const tmp = actorState.role;
      actorState.role = targetState.role;
      targetState.role = tmp;
      // log a private message for actor
      actorState.privateLog.push(`You swapped with ${target}. Your new role: ${actorState.role}`);
    }
  }
};

export default Robber;
```

### Role registry

- Central file roles/index.ts imports role modules and registers them:

```typescript
const ROLE_REGISTRY: Record<RoleId, RoleDefinition> = {
  robber: require('./robber').default,
  seer: require('./seer').default,
  werewolf: require('./werewolf').default,
  // ...
};
export default ROLE_REGISTRY;
```

### Advantages

- To add a role: create roles/newRole.ts, export RoleDefinition, add to registry.
- Role definitions include UI hints so the client can render correct prompts without embedding behavior.

## Night-resolution engine

One Night requires careful ordering and handling of simultaneous actions. Design a deterministic engine that:

1. Defines the night order: an array of role IDs in canonical order. Some games use role priority permutations; allow custom ordering via game options.
2. For each role in order:
  - For each player who currently has that role (initially based on `originalRole`, or game-specific), prompt the player to perform the role's nightAction (via boardgame.io `playerView` and `moves`).
  - Collect player actions into `G.nightActions`.
  - Immediately apply `role.nightAction.perform` server-side as actions arrive OR collect and apply at the end of the night step depending on role semantics. (Prefer applying immediately in the canonical order — simpler & deterministic.)
3. Atomicity & Validation:
  - All actions validated on server.
  - If a player's connection drops, wait until they rejoin.

Implementation notes:

- Use a phase `night` with substate `nightStep` index and `currentRole` string.
- Use a move `executeNightAction({target, extra})` which:
  - Validates actor has that role (or if role allows multiple).
  - Validates allowed targets.
  - Calls the role's `perform` function with `G`, `ctx`, and action params.
- Keep a `privateLog` for each player for night results (seer looks, robber message, etc).

## Client details

- React + boardgame.io React client:
  - Use `Client` from `boardgame.io/react` to bind to the Game and server.
  - UI modules:
    - `Lobby` (join/select seats)
    - `Board` (main game UI)
    - `NightPrompt` (render prompts per `role.nightAction.uiPrompt`)
    - `Discussion` (chat/timer)
    - `VotePanel` (cast votes)
    - `Reveal` (end-of-game summary)
- UI driven by role metadata:
  - Each role module provides a `uiPrompt` descriptor which the client uses to render the correct controls.
  - This avoids hardcoding UI per role.

### Client responsibilities

- Present prompts and send validated move payloads.
- Render only what boardgame.io gives (server authoritative).
- Use `playerView` to get private vs public info.

## Moves & API design (server-side `moves`)

- `startGame(options)`: initialize `G`, shuffle roles, allow game host to configure enabling/disabling roles, assign `originalRole` and `role`.
- `seatPlayer(seat)`, `leaveSeat()`.
- `startNight()`: move into `night` phase, set `nightOrder`.
- `executeNightAction(payload)`: allowed during `night` phase. Validates role correctness and delegates to role `perform`.
- `endNight()`: finalize and move to `day`.
- `castVote(targetPlayerID)`: record vote in `G.votes`.
- `finalizeVotes()`: tally, compute winners, set `G.revealed`.
- `resetGame()`: prepare for next round.

All moves validate `ctx.phase` and `ctx.currentPlayer`/`playerID` as necessary.

### Example: `executeNightAction` (pseudo-TS)
```typescript
function executeNightAction(G, ctx, { actor, roleId, payload }) {
  // basic checks
  if (ctx.phase !== 'night') throw new Error('Not night');
  if (!G.players[actor]) throw new Error('Invalid actor');
  const roleDef = ROLE_REGISTRY[roleId];
  if (!roleDef || !roleDef.nightAction) throw new Error('Role cannot act at night');

  // optionally ensure actor currently has that role or is allowed
  if (G.players[actor].role !== roleId) throw new Error('You do not have that role');

  // validate payload using roleDef.nightAction.validator (optional)
  roleDef.nightAction.perform(G, ctx, { actor, ...payload });

  // record in G.nightActions for audit / recount
  G.nightActions.push({ actor, roleId, payload, timestamp: Date.now() });
  return G;
}
```

## PlayerView & secrecy

- boardgame.io offers built-in `playerView` helpers. Add a custom `playerView` implementation that:
  - For each player’s client, includes that player's `role` and `privateLog` but strips other players' private logs and roles.
  - Always includes public facts (center cards as `?` unless seer-like role looked).
  - Explicitly deny any state leaking.

Example:

```typescript
const Game = {
  // ...
  playerView: (G, ctx, playerID) => {
    // deep copy G, then:
    // - reveal G.players[playerID].role
    // - hide other players' roles (maybe reveal known info)
    // - expose privateLog for playerID
  }
}
```

## Extensibility: Adding new roles

1. Create `roles/newRole.ts` implementing `RoleDefinition`.
2. Add to `roles/index.ts` registry.
3. Update `gameOptions` (role pool/shuffle rules) if needed.
4. Tests: add unit tests for role behavior and night ordering.

Because roles define `nightAction` shape, UI automatically picks up prompts and shows correct controls. Because `perform` mutates the server `G` in a limited and tested way, adding roles won’t require changes to core engine.

## File structure (example)
```
/src
  /server
    game.ts                // boardgame.io Game definition, phases, moves
    server.ts              // server entry (boardgame.io server or express wrapper)
    /roles
      index.ts             // registry
      seer.ts
      robber.ts
      werewolf.ts
      ...
    /util
      nightEngine.ts       // sequencing helpers, validators
      persistence.ts       // optional DB integration
    types.ts
  /client
    index.tsx              // React entry (Client from boardgame.io)
    App.tsx
    components/
      Lobby.tsx
      Board.tsx
      NightPrompt.tsx      // generic renderer for uiPrompt shapes
      VotePanel.tsx
      RevealPanel.tsx
    styles/
  package.json
  tsconfig.json
  .parcelrc
  README.md
```

## Testing strategy

- Unit tests for role `perform` functions using Jest (simulate G and ctx).
- Integration tests for night engine ordering and complex role interactions (e.g., robber swaps then seer sees).
- Skip E2E tests (Playwright) for client flow such as reconnect, vote, lobby flows for now.
- Property tests (optional) for invariants: total roles preserved, no role duplication beyond allowed.

## Reliability & UX concerns

- Connection drops: boardgame.io handles reconnection; ensure UI shows connection statuses of players.
- Latency: clients can be optimistic, but always enforce server validation.
- Cheating / manipulation: All sensitive logic on server; client only displays what server returns.
- Spectators: using boardgame.io spectator mode, return `playerView` with no private info. Game rules should allow/disallow spectating as desired.

## Example Parcel setup & dev experience

- `parcel` offers a zero-config dev server and fast HMR. Use `parcel` for client bundling:
  - `parcel src/client/index.html --port 1234`
- For TS support, configure `tsconfig.json`. Minimal `.parcelrc` for advanced needs.

- Example scripts:

```json
"scripts": {
  "dev": "concurrently \"node src/server/server.ts\" \"parcel src/client/index.html\"",
  "build": "parcel build src/client/index.html && tsc --build",
  "start": "node dist/server.js"
}
```

## Deployment considerations

- For production, run boardgame.io server under Node behind a load balancer.
- Skip persistence across restarts or multiple servers for now; assume the game runs as a single ephemeral instance that doesn't need to store state (stateless workload).
- Skip this for now, but keep in mind that later, we may want to add OAuth authentication.

## Documentation & onboarding

- Role Readme: each role module has header comment describing semantics, edge-cases, and tests.
- Contributor Guide: how to add roles, run tests, and run the dev server.
- Game Rule Tests: encode official rule interpretations as tests (e.g., how swapped roles affect win conditions).

### Example: Adding a New Role — checklist

1. Create `roles/fox.ts` (or similar) following `RoleDefinition`.
2. Implement `nightAction.perform` and optionally `onAction`.
3. Add to `roles/index.ts` registry.
4. Add unit tests in `__tests__/roles/fox.test.ts`.
5. Update `gameOptions` role pool config (if dynamic).
6. Start game and verify via `NightPrompt` UI (which will render according to `uiPrompt`).

## Roadmap / Future enhancements

- Matchmaking & ranking.
- Record playback of the game (for debugging and highlights).
- Mobile-first UI refinements and offline assistive features.

## Appendix — Sample RoleDefinition Type
```typescript
interface NightActionSpec {
  uiPrompt?: {
    type: "choosePlayer" | "chooseCenter" | "noPrompt" | "choosePlayers";
    min?: number;
    max?: number;
    label?: string;
    extraFields?: any;
  };
  validator?: (G, ctx, payload) => boolean; // throw or return false on bad
  perform: (G, ctx, payload: any) => void;
}

interface RoleDefinition {
  id: RoleId;
  name: string;
  description?: string;
  nightAction?: NightActionSpec;
  // Called after all night actions complete (optional)
  onNightEnd?: (G, ctx) => void;
  // scoring hook
  scoring?: (G, ctx) => void;
}
```

## Final notes / Principles

- Keep logic server-first. UI mirrors role metadata only.
- Keep role modules pure and testable: functions that accept `G`, `ctx`, `args` and mutate `G` deterministically.
- Keep `G` shape explicit and minimal. Avoid storing derived values when possible — compute them when needed.
- Document everything in code headers so new contributors can add roles safely.