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
    
    broadcastToAll('gameCreated', game);

    const response: ApiResponse = {
      success: true,
      data: game
    };
    res.status(201).json(response);
  });

  router.post('/games/:gameId/join', (req, res) => {
    const { gameId } = req.params;
    const { playerName, existingPlayerId }: { playerName?: string; existingPlayerId?: string } = req.body;

    // Joining as existing disconnected player
    if (existingPlayerId) {
      if (!existingPlayerId.trim()) {
        const response: ApiResponse = {
          success: false,
          error: 'Player ID is required'
        };
        return res.status(400).json(response);
      }

      const result = gameStateManager.rejoinPlayer(gameId, existingPlayerId.trim());
      
      if (!result) {
        const response: ApiResponse = {
          success: false,
          error: 'Game or player not found, or player is already connected'
        };
        return res.status(404).json(response);
      }

      // Set player as connected
      gameStateManager.updatePlayerConnection(gameId, result.player.id, true);
      
      // Get updated game state after connection update
      const updatedGame = gameStateManager.getGame(gameId);

      broadcastToGame(gameId, 'playerJoined', { player: result.player, game: updatedGame });

      const response: ApiResponse = {
        success: true,
        data: { player: result.player, game: updatedGame }
      };
      return res.json(response);
    }

    // Joining as new player
    if (!playerName || playerName.trim() === '') {
      const response: ApiResponse = {
        success: false,
        error: 'Player name is required when joining as new player'
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

    // Set player as connected
    gameStateManager.updatePlayerConnection(gameId, player.id, true);
    
    const game = gameStateManager.getGame(gameId);
    
    broadcastToGame(gameId, 'playerJoined', { player, game });

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

    // Set player as connected
    gameStateManager.updatePlayerConnection(gameId, result.player.id, true);
    
    // Get updated game state after connection update
    const updatedGame = gameStateManager.getGame(gameId);

    broadcastToGame(gameId, 'playerJoined', { player: result.player, game: updatedGame });

    const response: ApiResponse = {
      success: true,
      data: { player: result.player, game: updatedGame }
    };
    res.json(response);
  });

  router.post('/games/:gameId/players/:playerId/disconnect', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const updated = gameStateManager.updatePlayerConnection(gameId, playerId, false);
    
    if (!updated) {
      const response: ApiResponse = {
        success: false,
        error: 'Player or game not found'
      };
      return res.status(404).json(response);
    }

    const game = gameStateManager.getGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, 'gameState', game);
    }

    const response: ApiResponse = {
      success: true,
      data: { disconnected: true }
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
      broadcastToGame(gameId, 'playerLeft', { playerId, game });
    } else {
      broadcastToAll('gameDeleted', { gameId });
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

    broadcastToAll('gameDeleted', { gameId });

    const response: ApiResponse = {
      success: true,
      data: { deleted: true }
    };
    res.json(response);
  });

  return router;
}