import { GameState, Player, StateLobby } from '../types';

interface PlayerSocketMapping {
  gameId: string;
  playerId: string;
  socketId: string;
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
      lastActivity: new Date()
    };
    
    this.games.set(id, game);
    return game;
  }

  getGame(id: string): GameState | undefined {
    return this.games.get(id);
  }

  getAllGames(): GameState[] {
    return Array.from(this.games.values());
  }

  deleteGame(id: string): boolean {
    return this.games.delete(id);
  }

  addPlayer(gameId: string, playerName: string): Player | null {
    const game = this.games.get(gameId);
    if (!game) return null;

    const playerId = this.generatePlayerId();
    
    const player: Player = {
      id: playerId,
      name: playerName,
      connected: true
    };

    game.players.push(player);
    game.lastActivity = new Date();

    return player;
  }

  removePlayer(gameId: string, playerId: string): boolean {
    const game = this.games.get(gameId);
    if (!game) return false;

    const playerIndex = game.players.findIndex(p => p.id === playerId);
    if (playerIndex === -1) return false;

    game.players.splice(playerIndex, 1);
    game.lastActivity = new Date();

    if (game.players.length === 0) {
      this.games.delete(gameId);
    }

    return true;
  }

  updatePlayerConnection(gameId: string, playerId: string, connected: boolean): boolean {
    const game = this.games.get(gameId);
    if (!game) return false;

    const player = game.players.find(p => p.id === playerId);
    if (!player) return false;

    player.connected = connected;
    game.lastActivity = new Date();
    return true;
  }

  rejoinPlayer(gameId: string, playerId: string): { player: Player; game: GameState } | null {
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
    game.lastActivity = new Date();

    return { player, game };
  }

  private generateGameId(): string {
    return Math.random().toString(10).substring(2, 8);
  }

  private generatePlayerId(): string {
    return Math.random().toString(36).substring(2, 15);
  }

  // Socket registry methods
  registerPlayerSocket(gameId: string, playerId: string, socketId: string): boolean {
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
    game.lastActivity = new Date();

    return true;
  }

  unregisterSocket(socketId: string): PlayerSocketMapping | null {
    const mapping = this.socketToPlayer.get(socketId);
    if (!mapping) return null;

    // Remove from both mappings
    this.socketToPlayer.delete(socketId);
    this.playerToSocket.delete(mapping.playerId);

    // Update player connection status
    this.updatePlayerConnection(mapping.gameId, mapping.playerId, false);

    return mapping;
  }

  getSocketMapping(socketId: string): PlayerSocketMapping | null {
    return this.socketToPlayer.get(socketId) || null;
  }

  getPlayerSocket(playerId: string): string | null {
    return this.playerToSocket.get(playerId) || null;
  }

  isPlayerConnected(playerId: string): boolean {
    return this.playerToSocket.has(playerId);
  }

}

export const gameStateManager = new GameStateManager();