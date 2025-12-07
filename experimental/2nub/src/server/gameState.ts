import { GameState, Player, StateLobby } from '../types';

class GameStateManager {
  private games: Map<string, GameState> = new Map();

  createGame(name: string): GameState {
    const id = this.generateGameId();
    const game: GameState = {
      id,
      name,
      players: [],
      roleOrder: [],
      gameLog: [],
      state: { state: 'lobby' } as StateLobby,
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

  private generateGameId(): string {
    return Math.random().toString(10).substring(2, 8);
  }

  private generatePlayerId(): string {
    return Math.random().toString(36).substring(2, 15);
  }

}

export const gameStateManager = new GameStateManager();