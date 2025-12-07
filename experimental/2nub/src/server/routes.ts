import { Router } from 'express';
import { gameStateManager } from './gameState';
import { broadcastToGame, broadcastToAll } from './websocket';
import { CreateGameRequest, JoinGameRequest, ApiResponse } from '../types';

export function setupRoutes(): Router {
  const router = Router();

  router.get('/games', (req, res) => {
    const games = gameStateManager.getAllGames();
    const response: ApiResponse = {
      success: true,
      data: games
    };
    res.json(response);
  });

  router.get('/games/:gameId', (req, res) => {
    const { gameId } = req.params;
    const game = gameStateManager.getGame(gameId);
    
    if (!game) {
      const response: ApiResponse = {
        success: false,
        error: 'Game not found'
      };
      return res.status(404).json(response);
    }

    const response: ApiResponse = {
      success: true,
      data: game
    };
    res.json(response);
  });

  router.post('/games', (req, res) => {
    const { name }: CreateGameRequest = req.body;
    
    if (!name || name.trim().length === 0) {
      const response: ApiResponse = {
        success: false,
        error: 'Invalid game parameters'
      };
      return res.status(400).json(response);
    }

    const game = gameStateManager.createGame(name.trim());
    
    broadcastToAll({
      type: 'gameCreated',
      data: game
    });

    const response: ApiResponse = {
      success: true,
      data: game
    };
    res.status(201).json(response);
  });

  router.post('/games/:gameId/join', (req, res) => {
    const { gameId } = req.params;
    const { playerName }: { playerName: string } = req.body;

    if (!playerName || playerName.trim() === '') {
      const response: ApiResponse = {
        success: false,
        error: 'Player name is required'
      };
      return res.status(400).json(response);
    }

    const player = gameStateManager.addPlayer(gameId, playerName.trim());
    
    if (!player) {
      const response: ApiResponse = {
        success: false,
        error: 'Game not found or full'
      };
      return res.status(400).json(response);
    }

    const game = gameStateManager.getGame(gameId);
    
    broadcastToGame(gameId, {
      type: 'playerJoined',
      data: { player, game },
      gameId
    });

    const response: ApiResponse = {
      success: true,
      data: { player, game }
    };
    res.status(201).json(response);
  });

  router.post('/games/:gameId/rejoin', (req, res) => {
    const { gameId } = req.params;
    const { playerId }: { playerId: string } = req.body;

    if (!playerId || playerId.trim() === '') {
      const response: ApiResponse = {
        success: false,
        error: 'Player ID is required'
      };
      return res.status(400).json(response);
    }

    const result = gameStateManager.rejoinPlayer(gameId, playerId.trim());
    
    if (!result) {
      const response: ApiResponse = {
        success: false,
        error: 'Game or player not found'
      };
      return res.status(404).json(response);
    }

    broadcastToGame(gameId, {
      type: 'playerJoined',
      data: { player: result.player, game: result.game },
      gameId
    });

    const response: ApiResponse = {
      success: true,
      data: { player: result.player, game: result.game }
    };
    res.json(response);
  });

  router.delete('/games/:gameId/players/:playerId', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const removed = gameStateManager.removePlayer(gameId, playerId);
    
    if (!removed) {
      const response: ApiResponse = {
        success: false,
        error: 'Player or game not found'
      };
      return res.status(404).json(response);
    }

    const game = gameStateManager.getGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, {
        type: 'playerLeft',
        data: { playerId, game },
        gameId
      });
    } else {
      broadcastToAll({
        type: 'gameDeleted',
        data: { gameId }
      });
    }

    const response: ApiResponse = {
      success: true,
      data: { removed: true }
    };
    res.json(response);
  });

  router.delete('/games/:gameId', (req, res) => {
    const { gameId } = req.params;
    
    const deleted = gameStateManager.deleteGame(gameId);
    
    if (!deleted) {
      const response: ApiResponse = {
        success: false,
        error: 'Game not found'
      };
      return res.status(404).json(response);
    }

    broadcastToAll({
      type: 'gameDeleted',
      data: { gameId }
    });

    const response: ApiResponse = {
      success: true,
      data: { deleted: true }
    };
    res.json(response);
  });

  return router;
}