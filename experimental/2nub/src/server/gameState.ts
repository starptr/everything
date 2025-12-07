import { GameState, Player } from '../types';

class GameStateManager {
  private games: Map<string, GameState> = new Map();

  createGame(name: string, maxPlayers: number): GameState {
    const id = this.generateGameId();
    const game: GameState = {
      id,
      name,
      players: {},
      maxPlayers,
      status: 'waiting',
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

    if (Object.keys(game.players).length >= game.maxPlayers) {
      return null;
    }

    const playerId = this.generatePlayerId();
    const seat = this.getNextAvailableSeat(game);
    
    const player: Player = {
      id: playerId,
      name: playerName,
      seat,
      connected: true
    };

    game.players[playerId] = player;
    game.lastActivity = new Date();

    return player;
  }

  removePlayer(gameId: string, playerId: string): boolean {
    const game = this.games.get(gameId);
    if (!game || !game.players[playerId]) return false;

    delete game.players[playerId];
    game.lastActivity = new Date();

    if (Object.keys(game.players).length === 0) {
      this.games.delete(gameId);
    }

    return true;
  }

  updatePlayerConnection(gameId: string, playerId: string, connected: boolean): boolean {
    const game = this.games.get(gameId);
    if (!game || !game.players[playerId]) return false;

    game.players[playerId].connected = connected;
    game.lastActivity = new Date();
    return true;
  }

  private generateGameId(): string {
    return Math.random().toString(10).substring(2, 8);
  }

  private generatePlayerId(): string {
    return Math.random().toString(36).substring(2, 15);
  }

  private getNextAvailableSeat(game: GameState): number {
    const takenSeats = new Set(Object.values(game.players).map(p => p.seat));
    for (let seat = 1; seat <= game.maxPlayers; seat++) {
      if (!takenSeats.has(seat)) {
        return seat;
      }
    }
    return 1;
  }
}

export const gameStateManager = new GameStateManager();