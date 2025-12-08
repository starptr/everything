import { GameState, Player, StateLobby, StateNight } from '../types';

interface PlayerSocketMapping {
  gameId: string;
  playerId: string;
  socketId: string;
}

/**
 * Returns a promise which acts as a delay for the specified milliseconds.
 * @param ms Milliseconds to delay
 */
function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * @returns Promise that resolves after a standard delay (3-5 seconds)
 */
function standardDelay(): Promise<void> {
  const STANDARD_DELAY_MIN = 3000;
  const STANDARD_DELAY_MAX = 5000;
  const delayMs = Math.floor(Math.random() * (STANDARD_DELAY_MAX - STANDARD_DELAY_MIN + 1)) + STANDARD_DELAY_MIN;
  return delay(delayMs);
}

/**
 * Randomly returns true with probability p.
 * @param p Probability of true
 */
function flip(p: number): boolean {
  return Math.random() < p;
}

function shuffle<T>(array: T[]): T[] {
  const a = [...array]; // Copy to avoid mutating
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/*
 * Selects n random elements from the array, and returns a tuple of
 * [selectedElements, remainingElements].
 * Preserves the original order of elements.
 */
function chooseN<T>(array: T[], n: number): [T[], T[]] {
  array = [...array]; // Copy to avoid mutating
  if (n < 0 || n > array.length) {
    throw new Error("n must be between 0 and array length");
  }
  // Generate a list of all indices
  const indices = array.map((_, i) => i);
  // Shuffle the indices
  const shuffledIndices = shuffle(indices);
  // Select the first n indices
  const selectedIndices = new Set(shuffledIndices.slice(0, n));
  // Partition the array based on selected indices
  const selected: T[] = [];
  const remaining: T[] = [];
  array.forEach((item, index) => {
    if (selectedIndices.has(index)) {
      selected.push(item);
    } else {
      remaining.push(item);
    }
  });
  return [selected, remaining];
}

class GameStateManager {
  private games: Map<string, GameState> = new Map();
  private socketToPlayer: Map<string, PlayerSocketMapping> = new Map();
  private playerToSocket: Map<string, string> = new Map();

  createGame(name: string): GameState {
    const id = this.generateGameId();
    const game: GameState = {
      id,
      name,
      players: [],
      gameLog: [],
      state: {
        state: 'lobby',
        ruleset: {
          roleOrder: [],
          special: {
            maybeAllTanners: {
              enabled: false,
              probability: 0.05
            },
          },
        },
      },
      createdAt: new Date(),
    };
    
    this.games.set(id, game);
    return game;
  }

  maybeGetGame(id: string): GameState | undefined {
    return this.games.get(id);
  }

  getAllGames(): GameState[] {
    return Array.from(this.games.values());
  }

  maybeDeleteGame(id: string): boolean {
    return this.games.delete(id);
  }

  maybeAddPlayer(gameId: string, playerName: string): Player | null {
    const game = this.games.get(gameId);
    if (!game) return null;

    const playerId = this.generatePlayerId();
    
    const player: Player = {
      id: playerId,
      name: playerName,
      connected: true
    };

    game.players.push(player);

    return player;
  }

  maybeRemovePlayer(gameId: string, playerId: string): boolean {
    const game = this.games.get(gameId);
    if (!game) return false;

    const playerIndex = game.players.findIndex(p => p.id === playerId);
    if (playerIndex === -1) return false;

    game.players.splice(playerIndex, 1);

    if (game.players.length === 0) {
      this.games.delete(gameId);
    }

    return true;
  }

  maybeUpdatePlayerConnection(gameId: string, playerId: string, connected: boolean): boolean {
    const game = this.games.get(gameId);
    if (!game) return false;

    const player = game.players.find(p => p.id === playerId);
    if (!player) return false;

    player.connected = connected;
    return true;
  }

  maybeRejoinPlayer(gameId: string, playerId: string): { player: Player; game: GameState } | null {
    console.debug(`Attempting to rejoin player ${playerId} to game ${gameId}`);
    const game = this.games.get(gameId);
    if (!game) {
      console.debug(`Rejoin failed: game ${gameId} not found`);
      return null;
    }

    const player = game.players.find(p => p.id === playerId);
    if (!player) {
      console.debug(`Rejoin failed: player ${playerId} not found in game ${gameId}`);
      return null;
    }

    // Only allow rejoining if player is currently disconnected
    if (player.connected) return null;

    player.connected = true;

    return { player, game };
  }

  private generateGameId(): string {
    return Math.random().toString(10).substring(2, 8);
  }

  private generatePlayerId(): string {
    return Math.random().toString(36).substring(2, 15);
  }

  // Socket registry methods
  maybeRegisterPlayerSocket(gameId: string, playerId: string, socketId: string): boolean {
    const game = this.games.get(gameId);
    if (!game) return false;

    const player = game.players.find(p => p.id === playerId);
    if (!player) return false;

    // Remove any existing socket for this player
    const existingSocketId = this.playerToSocket.get(playerId);
    if (existingSocketId) {
      this.socketToPlayer.delete(existingSocketId);
    }

    // Register the new socket
    const mapping: PlayerSocketMapping = { gameId, playerId, socketId };
    this.socketToPlayer.set(socketId, mapping);
    this.playerToSocket.set(playerId, socketId);

    // Update player connection status
    player.connected = true;

    return true;
  }

  maybeUnregisterSocket(socketId: string): PlayerSocketMapping | null {
    const mapping = this.socketToPlayer.get(socketId);
    if (!mapping) return null;

    // Remove from both mappings
    this.socketToPlayer.delete(socketId);
    this.playerToSocket.delete(mapping.playerId);

    // Update player connection status
    this.maybeUpdatePlayerConnection(mapping.gameId, mapping.playerId, false);

    return mapping;
  }

  maybeGetSocketMapping(socketId: string): PlayerSocketMapping | null {
    return this.socketToPlayer.get(socketId) || null;
  }

  maybeGetPlayerSocket(playerId: string): string | null {
    return this.playerToSocket.get(playerId) || null;
  }

  isPlayerConnected(playerId: string): boolean {
    return this.playerToSocket.has(playerId);
  }

  maybeUpdateRuleset(gameId: string, newRuleset: StateLobby["ruleset"]): GameState | null {
    const game = this.games.get(gameId);
    if (!game) return null;

    // Only allow updating ruleset if game is in lobby state
    if (game.state.state !== 'lobby') return null;

    // Update the ruleset
    game.state.ruleset = newRuleset;

    return game;
  }

  async maybeStartGame(gameId: string): Promise<GameState | null> {
    const game = this.games.get(gameId);
    if (!game) return null;

    // Only allow starting the game if invariants hold
    if (game.state.state !== 'lobby') return null;
    else if (game.players.length + 3 !== game.state.ruleset.roleOrder.length) return null;

    await standardDelay();

    // Transition to in-game state

    if (game.state.ruleset.special.maybeAllTanners.enabled) {
      if (flip(game.state.ruleset.special.maybeAllTanners.probability)) {
        // Set all players to Tanner
        game.state = {
          state: 'night',
          playerData: Object.fromEntries(
            game.players.map(player => [player.id, {
              originalRoleId: 'tanner',
              currentRoleId: 'tanner',
              playerLog: [],
            }])
          ),
          centerCards: ['tanner', 'tanner', 'tanner'],
          ruleset: { ...game.state.ruleset },
        }
        return game;
      }
    }

    const [unshuffledCenterCards, remainingRoles] = chooseN(game.state.ruleset.roleOrder, 3);
    const centerCards = shuffle(unshuffledCenterCards);

    const playerIds = shuffle(game.players.map(p => p.id));
    const playerData: StateNight["playerData"] = Object.fromEntries(
      playerIds.map((id, index) => [id, {
        originalRoleId: remainingRoles[index],
        currentRoleId: remainingRoles[index],
        playerLog: [],
      }])
    );

    game.state = {
      state: 'night',
      playerData,
      centerCards,
      ruleset: { ...game.state.ruleset },
    }

    return game;
  }
}

export const gameStateManager = new GameStateManager();