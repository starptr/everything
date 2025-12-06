# One Night Ultimate Werewolf

A web-based implementation of One Night Ultimate Werewolf using boardgame.io, React, and TypeScript.

## Features

- **Full Game Implementation**: Complete implementation of classic One Night Ultimate Werewolf
- **Multiplayer Support**: Real-time multiplayer with boardgame.io
- **Role System**: Modular role definitions including Werewolf, Seer, Robber, Troublemaker, and Villager
- **Night Phase**: Automated night resolution with role-specific actions
- **Secure**: Server-authoritative game logic with proper secret hiding
- **Modern UI**: React-based interface with responsive design

## Installation

1. Clone the repository
2. Install dependencies:
   ```bash
   npm install
   ```

## Development

### Start Development Server

Run both the game server and client in development mode:

```bash
npm run dev
```

This will start:
- Game server on `http://localhost:8000`
- Client on `http://localhost:3000`

### Individual Services

Start just the server:
```bash
npm run dev:server
```

Start just the client:
```bash
npm run dev:client
```

## Building

Build for production:

```bash
npm run build
```

This creates:
- Compiled server code in `dist/server/`
- Client bundle in `dist/client/`

## Production

Start the production server:

```bash
npm start
```

Make sure to serve the client files (in `dist/client/`) from a web server.

## Game Rules

### Setup
- 3-10 players can join a game
- Each player receives a secret role card
- 3 additional role cards are placed in the center

### Night Phase
1. **Werewolves** - Look for other werewolves. If alone, look at a center card
2. **Seer** - Look at another player's card OR two center cards
3. **Robber** - Swap your card with another player and look at your new role
4. **Troublemaker** - Swap two other players' cards (without looking)

### Day Phase
- Open discussion phase where players share information (or bluff!)
- Players try to figure out who the werewolves are

### Voting Phase
- All players vote simultaneously for who they think is a werewolf
- Players with the most votes are eliminated

### Victory Conditions
- **Village Team**: Wins if at least one werewolf is eliminated
- **Werewolf Team**: Wins if no werewolves are eliminated

## Architecture

### Server (boardgame.io)
- **Game Logic**: Core game rules and state management
- **Role System**: Modular role definitions in `src/server/roles/`
- **Night Engine**: Automated sequencing of night actions
- **Security**: Server-authoritative with proper secret management

### Client (React)
- **Phase Components**: Separate UI for each game phase
- **Responsive Design**: Works on desktop and mobile
- **Real-time Updates**: Automatic synchronization with game state

### File Structure
```
src/
├── server/
│   ├── game-simple.ts          # Main game definition
│   ├── server.ts              # Server setup
│   ├── types.ts               # TypeScript type definitions
│   ├── roles/                 # Role definitions
│   │   ├── index.ts           # Role registry
│   │   ├── werewolf.ts
│   │   ├── seer.ts
│   │   ├── robber.ts
│   │   ├── troublemaker.ts
│   │   └── villager.ts
│   └── util/
│       └── nightEngine.ts     # Night resolution logic
└── client/
    ├── index.tsx              # React entry point
    ├── App.tsx                # Main app component
    └── components/            # React components
        ├── Board.tsx          # Main game board
        ├── Lobby.tsx          # Pre-game lobby
        ├── NightPhase.tsx     # Night phase UI
        ├── DayPhase.tsx       # Day phase UI
        ├── VotingPhase.tsx    # Voting UI
        └── RevealPhase.tsx    # End game results
```

## Adding New Roles

1. Create a new role file in `src/server/roles/`
2. Implement the `RoleDefinition` interface
3. Add night action logic if needed
4. Register in `src/server/roles/index.ts`
5. Update `NIGHT_ORDER` in `types.ts` if the role acts at night

Example:
```typescript
import { RoleDefinition } from "../types";

const MyRole: RoleDefinition = {
  id: "myrole",
  name: "My Role",
  description: "Does something interesting",
  team: "village", // or "werewolf" or "special"
  nightAction: {
    // ... action definition
  }
};

export default MyRole;
```

## Testing

Run tests:
```bash
npm test
```

Watch mode:
```bash
npm run test:watch
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new features
5. Submit a pull request

## License

MIT License - see LICENSE file for details