import request from 'supertest';
import express from 'express';
import { setupRoutes } from '../../src/server/routes';
import { gameStateManager } from '../../src/server/gameState';

const app = express();
app.use(express.json());
app.use('/api', setupRoutes());

describe('Game API Routes', () => {
  beforeEach(() => {
    (gameStateManager as any).games.clear();
  });

  describe('GET /api/games', () => {
    it('should return empty array when no games exist', async () => {
      const response = await request(app).get('/api/games');
      
      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data).toEqual([]);
    });

    it('should return all games', async () => {
      gameStateManager.createGame('Game 1');
      gameStateManager.createGame('Game 2');
      
      const response = await request(app).get('/api/games');
      
      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data).toHaveLength(2);
    });
  });

  describe('POST /api/games', () => {
    it('should create a new game', async () => {
      const gameData = { name: 'Test Game' };
      
      const response = await request(app)
        .post('/api/games')
        .send(gameData);
      
      expect(response.status).toBe(201);
      expect(response.body.success).toBe(true);
      expect(response.body.data.name).toBe('Test Game');
    });

    it('should reject invalid game data', async () => {
      const invalidData = { name: '' };
      
      const response = await request(app)
        .post('/api/games')
        .send(invalidData);
      
      expect(response.status).toBe(400);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Invalid game parameters');
    });
  });

  describe('GET /api/games/:gameId', () => {
    it('should return a specific game', async () => {
      const game = gameStateManager.createGame('Test Game');
      
      const response = await request(app).get(`/api/games/${game.id}`);
      
      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data.id).toBe(game.id);
    });

    it('should return 404 for non-existent game', async () => {
      const response = await request(app).get('/api/games/INVALID');
      
      expect(response.status).toBe(404);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Game not found');
    });
  });

  describe('POST /api/games/:gameId/join', () => {
    it('should add a player to a game', async () => {
      const game = gameStateManager.createGame('Test Game');
      
      const response = await request(app)
        .post(`/api/games/${game.id}/join`)
        .send({ playerName: 'Alice' });
      
      expect(response.status).toBe(201);
      expect(response.body.success).toBe(true);
      expect(response.body.data.player.name).toBe('Alice');
      expect(response.body.data.game.id).toBe(game.id);
    });

    it('should reject empty player name', async () => {
      const game = gameStateManager.createGame('Test Game');
      
      const response = await request(app)
        .post(`/api/games/${game.id}/join`)
        .send({ playerName: '' });
      
      expect(response.status).toBe(400);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Player name is required');
    });

    it('should reject joining non-existent game', async () => {
      const response = await request(app)
        .post('/api/games/INVALID/join')
        .send({ playerName: 'Alice' });
      
      expect(response.status).toBe(400);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Game not found or full');
    });
  });

  describe('DELETE /api/games/:gameId/players/:playerId', () => {
    it('should remove a player from a game', async () => {
      const game = gameStateManager.createGame('Test Game');
      const player = gameStateManager.addPlayer(game.id, 'Alice');
      
      const response = await request(app)
        .delete(`/api/games/${game.id}/players/${player!.id}`);
      
      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data.removed).toBe(true);
    });

    it('should return 404 for non-existent player', async () => {
      const game = gameStateManager.createGame('Test Game');
      
      const response = await request(app)
        .delete(`/api/games/${game.id}/players/INVALID`);
      
      expect(response.status).toBe(404);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Player or game not found');
    });
  });

  describe('DELETE /api/games/:gameId', () => {
    it('should delete a game', async () => {
      const game = gameStateManager.createGame('Test Game');
      
      const response = await request(app).delete(`/api/games/${game.id}`);
      
      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data.deleted).toBe(true);
    });

    it('should return 404 for non-existent game', async () => {
      const response = await request(app).delete('/api/games/INVALID');
      
      expect(response.status).toBe(404);
      expect(response.body.success).toBe(false);
      expect(response.body.error).toBe('Game not found');
    });
  });
});