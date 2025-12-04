# One Night Ultimate Werewolf

A digital implementation of the popular social deduction game "One Night Ultimate Werewolf" built with boardgame.io, TypeScript, React, and Express.

## 🎮 Game Overview

One Night Ultimate Werewolf is a fast-paced social deduction game where players are assigned secret roles and must work together (or against each other) to achieve their win conditions. The game consists of a single night phase where certain roles perform actions, followed by a discussion phase and voting to eliminate suspected werewolves.

## 🏗️ Architecture

This implementation follows a modular, server-authoritative design:

- **Server**: Authoritative game state using boardgame.io with Express
- **Client**: React frontend with TypeScript for type safety
- **Roles System**: Modular role definitions for easy extensibility
- **Multiplayer**: Real-time updates via WebSocket connections

### Key Design Principles

1. **Server-First Logic**: All sensitive game logic runs on the server
2. **Modular Roles**: Easy to add new roles by implementing the `RoleDefinition` interface
3. **Type Safety**: Full TypeScript coverage for robust development
4. **Secrets Management**: playerView system ensures players only see authorized information
5. **Extensibility**: Clean interfaces for adding new features

## 🚀 Quick Start

### Prerequisites

- Node.js 18+ 
- npm or yarn

### Installation

```bash
# Install root dependencies
npm install

# Install client dependencies  
npm run client:install

# Or install all at once
npm run install:all
```

### Development

Run both server and client in development mode:

```bash
npm run dev
```

This will start:
- Server on `http://localhost:8000`
- Client on `http://localhost:1234`

### Individual Commands

```bash
# Server only
npm run server:dev

# Client only  
npm run client:dev

# Run tests
npm test

# Build for production
npm run build
```

## 🎯 How to Play

### Game Flow

1. **Lobby Phase**: Players join the game and select seats
2. **Night Phase**: Players with special roles perform their actions secretly
3. **Day Phase**: Open discussion about what happened during the night
4. **Voting Phase**: Each player votes to eliminate a suspected werewolf
5. **Reveal Phase**: All roles are revealed and winners are determined

### Roles Implemented

#### Werewolf
- **Goal**: Survive the vote
- **Night Action**: See other werewolves, or look at a center card if alone

#### Seer  
- **Goal**: Find and eliminate werewolves
- **Night Action**: Look at another player's card OR two center cards

#### Robber
- **Goal**: Help your new team (after swapping)
- **Night Action**: Swap your card with another player and learn your new role

#### Troublemaker
- **Goal**: Find and eliminate werewolves  
- **Night Action**: Swap two other players' cards (without looking)

#### Villager
- **Goal**: Find and eliminate werewolves
- **Night Action**: None - but still important for discussion!

### Win Conditions

- **Villagers win** if at least one werewolf is eliminated
- **Werewolves win** if no werewolves are eliminated
- **Special cases**: If no werewolves are in play, villagers win by not eliminating anyone OR by eliminating a villager

## 🔧 Development Guide

### Adding New Roles

1. Create a new role file in `src/server/roles/`:

```typescript
// src/server/roles/newrole.ts
import { RoleDefinition } from '../../shared/types';

export const NewRole: RoleDefinition = {
  id: 'newrole',
  name: 'New Role',
  description: 'Description of what this role does',
  nightOrder: 8, // When this role acts during night
  
  nightAction: {
    uiPrompt: {
      type: "choosePlayer", // or "noPrompt", "choosePlayers", etc.
      min: 1,
      max: 1,
      label: "Choose a player to target"
    },
    
    validator: (G, ctx, payload) => {
      // Validate the action payload
      return true;
    },
    
    perform: (G, ctx, { actor, target }) => {
      // Execute the role's night action
      const actorPlayer = G.players[actor];
      // Implement your role logic here
      actorPlayer.privateLog.push("You performed your action!");
    }
  }
};
```

2. Add to the role registry in `src/server/roles/index.ts`:

```typescript
import { NewRole } from './newrole';

export const ROLE_REGISTRY: Record<RoleId, RoleDefinition> = {
  // ... existing roles
  newrole: NewRole,
};
```

3. Add tests in `src/server/roles/__tests__/newrole.test.ts`

4. Update UI components if needed for custom prompts

### Testing

The project includes comprehensive Jest tests:

```bash
# Run all tests
npm test

# Run tests in watch mode  
npm run test:watch

# Run only role tests
npm run test:roles

# Run only server tests
npm run test:server
```

### Project Structure

```
src/
├── server/
│   ├── game.ts              # Main boardgame.io Game definition
│   ├── server.ts            # Express server setup
│   ├── roles/               # Role definitions
│   │   ├── index.ts         # Role registry
│   │   ├── werewolf.ts      # Individual role files
│   │   └── __tests__/       # Role tests
│   └── util/                # Utility functions
│       ├── gameUtils.ts     # Game helper functions
│       └── playerView.ts    # Secret management
├── shared/
│   └── types.ts             # Shared TypeScript types
└── client/                  # React frontend (separate package.json)
    └── src/
        ├── App.tsx          # Main app component
        └── components/      # React components
```

## 🎲 Game Rules Reference

### Night Order

Roles act in this specific order during the night phase:

1. **Doppelganger** *(not yet implemented)*
2. **Werewolf** - See other werewolves or a center card
3. **Minion** *(not yet implemented)* 
4. **Mason** *(not yet implemented)*
5. **Seer** - Look at player card or center cards
6. **Robber** - Swap with another player
7. **Troublemaker** - Swap two other players
8. **Drunk** *(not yet implemented)*
9. **Insomniac** *(not yet implemented)*
10. **Villager** - No action

### Voting Rules

- Each player must vote for someone (cannot vote for self)
- Player(s) with most votes are eliminated
- Ties result in all tied players being eliminated
- If no clear majority, specific tiebreaker rules apply

## 🚀 Deployment

### Production Build

```bash
npm run build
```

This creates:
- `dist/` - Compiled server code
- `client/dist/` - Built client assets

### Environment Variables

- `NODE_ENV` - Set to "production" for production builds
- `PORT` - Server port (default: 8000)
- `CLIENT_PORT` - Client dev server port (default: 1234)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/new-role`)
3. Add tests for any new functionality
4. Ensure all tests pass (`npm test`)
5. Submit a pull request

### Code Style

- Use TypeScript for all new code
- Follow existing naming conventions
- Add JSDoc comments for public APIs
- Ensure 100% test coverage for role logic

## 📝 License

ISC License - see LICENSE file for details

## 🎨 Credits

- Game design by Ted Alspach and Akihisa Okui
- Built with [boardgame.io](https://boardgame.io/)
- UI inspired by the original board game artwork