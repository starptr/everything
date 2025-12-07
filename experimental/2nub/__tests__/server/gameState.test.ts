import { gameStateManager } from '../../src/server/gameState';

describe('GameStateManager', () => {
  beforeEach(() => {
    (gameStateManager as any).games.clear();
  });

  describe('createGame', () => {
    it('should create a new game with correct properties', () => {
      const game = gameStateManager.createGame('Test Game');
      
      expect(game.name).toBe('Test Game');
      expect(game.players).toEqual([]);
      expect(game.state.state).toBe('lobby');
      expect(game.gameLog).toEqual([]);
      expect(game.roleOrder).toEqual([]);
      expect(game.id).toBeDefined();
      expect(game.id).toMatch(/^[0-9]{6}$/);
    });

    it('should add game to internal storage', () => {
      const game = gameStateManager.createGame('Test Game');
      const retrievedGame = gameStateManager.getGame(game.id);
      
      expect(retrievedGame).toEqual(game);
    });
  });

  describe('addPlayer', () => {
    it('should add a player to an existing game', () => {
      const game = gameStateManager.createGame('Test Game');
      const player = gameStateManager.addPlayer(game.id, 'Alice');
      
      expect(player).toBeDefined();
      expect(player!.name).toBe('Alice');
      expect(player!.connected).toBe(true);
      
      const updatedGame = gameStateManager.getGame(game.id);
      expect(updatedGame!.players).toHaveLength(1);
      expect(updatedGame!.players[0]).toEqual(player);
    });

    it('should add players to array in sequence', () => {
      const game = gameStateManager.createGame('Test Game');
      
      const player1 = gameStateManager.addPlayer(game.id, 'Alice');
      const player2 = gameStateManager.addPlayer(game.id, 'Bob');
      const player3 = gameStateManager.addPlayer(game.id, 'Charlie');
      
      const updatedGame = gameStateManager.getGame(game.id);
      expect(updatedGame!.players).toHaveLength(3);
      expect(updatedGame!.players[0]).toEqual(player1);
      expect(updatedGame!.players[1]).toEqual(player2);
      expect(updatedGame!.players[2]).toEqual(player3);
    });


    it('should return null for non-existent game', () => {
      const player = gameStateManager.addPlayer('INVALID', 'Alice');
      expect(player).toBeNull();
    });
  });

  describe('removePlayer', () => {
    it('should remove a player from the game', () => {
      const game = gameStateManager.createGame('Test Game');
      const player1 = gameStateManager.addPlayer(game.id, 'Alice');
      const player2 = gameStateManager.addPlayer(game.id, 'Bob');
      
      const removed = gameStateManager.removePlayer(game.id, player1!.id);
      expect(removed).toBe(true);
      
      const updatedGame = gameStateManager.getGame(game.id);
      expect(updatedGame!.players).toHaveLength(1);
      expect(updatedGame!.players[0]).toEqual(player2);
    });

    it('should delete game when last player leaves', () => {
      const game = gameStateManager.createGame('Test Game');
      const player = gameStateManager.addPlayer(game.id, 'Alice');
      
      gameStateManager.removePlayer(game.id, player!.id);
      
      const deletedGame = gameStateManager.getGame(game.id);
      expect(deletedGame).toBeUndefined();
    });

    it('should return false for non-existent player or game', () => {
      const removed = gameStateManager.removePlayer('INVALID', 'INVALID');
      expect(removed).toBe(false);
    });
  });

  describe('updatePlayerConnection', () => {
    it('should update player connection status', () => {
      const game = gameStateManager.createGame('Test Game');
      const player = gameStateManager.addPlayer(game.id, 'Alice');
      
      const updated = gameStateManager.updatePlayerConnection(game.id, player!.id, false);
      expect(updated).toBe(true);
      
      const updatedGame = gameStateManager.getGame(game.id);
      const updatedPlayer = updatedGame!.players.find(p => p.id === player!.id);
      expect(updatedPlayer!.connected).toBe(false);
    });

    it('should return false for non-existent player or game', () => {
      const updated = gameStateManager.updatePlayerConnection('INVALID', 'INVALID', false);
      expect(updated).toBe(false);
    });
  });

  describe('getAllGames', () => {
    it('should return all games', () => {
      gameStateManager.createGame('Game 1');
      gameStateManager.createGame('Game 2');
      
      const games = gameStateManager.getAllGames();
      expect(games).toHaveLength(2);
      expect(games.map(g => g.name)).toContain('Game 1');
      expect(games.map(g => g.name)).toContain('Game 2');
    });

    it('should return empty array when no games exist', () => {
      const games = gameStateManager.getAllGames();
      expect(games).toEqual([]);
    });
  });

  describe('deleteGame', () => {
    it('should delete a game', () => {
      const game = gameStateManager.createGame('Test Game');
      
      const deleted = gameStateManager.deleteGame(game.id);
      expect(deleted).toBe(true);
      
      const retrievedGame = gameStateManager.getGame(game.id);
      expect(retrievedGame).toBeUndefined();
    });

    it('should return false for non-existent game', () => {
      const deleted = gameStateManager.deleteGame('INVALID');
      expect(deleted).toBe(false);
    });
  });
});