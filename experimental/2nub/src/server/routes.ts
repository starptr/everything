import { Router, Response } from 'express';
import { gameStateManager } from './gameState';
import { broadcastToGame, broadcastToAll } from './websocket';
import { CreateGameRequest, JoinGameRequest, ApiResponse } from '../types';

// TODO: consider not returning `game` state in the HTTP response, since websockets should handle real time server-to-client data updates

function respondGameNotFound(res: Response, message: string | null) {
  return respondFailure(res, 404, message ? `Game not found: ${message}` : 'Game not found');
}

function respondSuccessWithData<T>(res: Response, status: number, data: T) {
  const response: ApiResponse = {
    success: true,
    data,
  };
  return res.status(status).json(response);
}

function respondFailure(res: Response, status: number, message: string) {
  const response: ApiResponse = {
    success: false,
    error: message,
  };
  return res.status(status).json(response);
}

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
      return respondGameNotFound(res, null);
    }
    return respondSuccessWithData(res, 200, game);
  });

  router.post('/games', (req, res) => {
    const { name }: CreateGameRequest = req.body;
    
    if (!name || name.trim().length === 0) {
      return respondFailure(res, 400, 'Invalid game parameters');
    }

    const game = gameStateManager.createGame(name.trim());
    
    broadcastToAll('gameCreated', game);

    return respondSuccessWithData(res, 201, game);
  });

  // TODO: consider removing rejoining logic from here since /rejoin exists
  router.post('/games/:gameId/join', (req, res) => {
    const { gameId } = req.params;
    const { playerName, existingPlayerId }: { playerName?: string; existingPlayerId?: string } = req.body;

    // Joining as existing disconnected player
    if (existingPlayerId) {
      if (!existingPlayerId.trim()) {
        return respondFailure(res, 400, 'Player ID is required');
      }

      const result = gameStateManager.rejoinPlayer(gameId, existingPlayerId.trim());
      
      if (!result) {
        return respondFailure(res, 404, 'Game or player not found, or player is already connected');
      }

      // Set player as connected
      gameStateManager.updatePlayerConnection(gameId, result.player.id, true);
      
      // Get updated game state after connection update
      const updatedGame = gameStateManager.getGame(gameId);

      if (!updatedGame) {
        return respondGameNotFound(res, null);
      }

      broadcastToGame(gameId, 'playerJoined', { player: result.player, game: updatedGame });

      return respondSuccessWithData(res, 200, {
        player: result.player,
        game: updatedGame
      });
    }

    // Joining as new player
    if (!playerName || playerName.trim() === '') {
      return respondFailure(res, 400, 'Player name is required when joining as new player');
    }

    const player = gameStateManager.addPlayer(gameId, playerName.trim());
    
    if (!player) {
      return respondFailure(res, 400, 'Game not found or full');
    }

    // Set player as connected
    gameStateManager.updatePlayerConnection(gameId, player.id, true);
    
    const game = gameStateManager.getGame(gameId);
    
    if (!game) {
      return respondGameNotFound(res, null);
    }

    broadcastToGame(gameId, 'playerJoined', { player, game });

    return respondSuccessWithData(res, 201, { player, game });
  });

  router.post('/games/:gameId/rejoin', (req, res) => {
    console.debug('Rejoin request received:', req.params, req.body);
    const { gameId } = req.params;
    const { playerId }: { playerId: string } = req.body;

    if (!playerId || playerId.trim() === '') {
      return respondFailure(res, 400, 'Player ID is required');
    }

    const result = gameStateManager.rejoinPlayer(gameId, playerId.trim());
    
    if (!result) {
      return respondFailure(res, 404, 'Game or player not found');
    }

    // Set player as connected
    gameStateManager.updatePlayerConnection(gameId, result.player.id, true);
    
    // Get updated game state after connection update
    const updatedGame = gameStateManager.getGame(gameId);

    if (!updatedGame) {
      return respondGameNotFound(res, null);
    }

    broadcastToGame(gameId, 'playerJoined', { player: result.player, game: updatedGame });

    return respondSuccessWithData(res, 200, { player: result.player, game: updatedGame });
  });

  router.post('/games/:gameId/players/:playerId/disconnect', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const updated = gameStateManager.updatePlayerConnection(gameId, playerId, false);
    
    if (!updated) {
      return respondFailure(res, 404, 'Player or game not found');
    }

    const game = gameStateManager.getGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, 'gameState', game);
    }

    return respondSuccessWithData(res, 200, { disconnected: true });
  });

  router.delete('/games/:gameId/players/:playerId', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const removed = gameStateManager.removePlayer(gameId, playerId);
    
    if (!removed) {
      return respondFailure(res, 404, 'Player or game not found');
    }

    const game = gameStateManager.getGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, 'playerLeft', { playerId, game });
    } else {
      broadcastToAll('gameDeleted', { gameId });
    }

    return respondSuccessWithData(res, 200, { removed: true });
  });

  router.delete('/games/:gameId', (req, res) => {
    const { gameId } = req.params;
    
    const deleted = gameStateManager.deleteGame(gameId);
    
    if (!deleted) {
      return respondGameNotFound(res, null);
    }

    broadcastToAll('gameDeleted', { gameId });

    return respondSuccessWithData(res, 200, { deleted: true });
  });

  return router;
}