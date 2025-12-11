import { Router, Response } from 'express';
import { gameStateManager } from './gameState';
import { broadcastToGame, broadcastToAll } from './websocket';
import { CreateGameRequest, JoinGameRequest, RejoinGameRequest, ApiResponse, GameState, GameStateClient } from '../types';

// Helper function to convert GameState to GameStateClient (remove ID)
function toGameStateClient(gameState: GameState): GameStateClient {
  const { id, ...gameStateClient } = gameState;
  return gameStateClient;
}


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
    const game = gameStateManager.maybeGetGame(gameId);
    
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

  router.post('/games/:gameId/join', (req, res) => {
    const { gameId } = req.params;
    const { playerName }: JoinGameRequest = req.body;

    if (!playerName || playerName.trim() === '') {
      return respondFailure(res, 400, 'Player name is required');
    }

    const player = gameStateManager.maybeAddPlayer(gameId, playerName.trim());
    
    if (!player) {
      return respondFailure(res, 400, 'Game not found or full');
    }

    // Set player as connected
    gameStateManager.maybeUpdatePlayerConnection(gameId, player.id, true);
    
    const game = gameStateManager.maybeGetGame(gameId);
    
    if (!game) {
      return respondGameNotFound(res, null);
    }

    broadcastToGame(gameId, 'playerJoined', { player, game: toGameStateClient(game) });

    return respondSuccessWithData(res, 201, { player });
  });

  router.post('/games/:gameId/rejoin', (req, res) => {
    console.debug('Rejoin request received:', req.params, req.body);
    const { gameId } = req.params;
    const { playerId }: RejoinGameRequest = req.body;

    if (!playerId || playerId.trim() === '') {
      return respondFailure(res, 400, 'Player ID is required');
    }

    const result = gameStateManager.maybeRejoinPlayer(gameId, playerId.trim());
    
    if (!result) {
      return respondFailure(res, 404, 'Game or player not found');
    }

    // Set player as connected
    gameStateManager.maybeUpdatePlayerConnection(gameId, result.player.id, true);
    
    // Get updated game state after connection update
    const updatedGame = gameStateManager.maybeGetGame(gameId);

    if (!updatedGame) {
      return respondGameNotFound(res, null);
    }

    broadcastToGame(gameId, 'playerJoined', { player: result.player, game: toGameStateClient(updatedGame) });

    return respondSuccessWithData(res, 200, { player: result.player });
  });

  router.post('/games/:gameId/players/:playerId/disconnect', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const updated = gameStateManager.maybeUpdatePlayerConnection(gameId, playerId, false);
    
    if (!updated) {
      return respondFailure(res, 404, 'Player or game not found');
    }

    const game = gameStateManager.maybeGetGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, 'gameState', toGameStateClient(game));
    }

    return respondSuccessWithData(res, 200, { disconnected: true });
  });

  router.delete('/games/:gameId/players/:playerId', (req, res) => {
    const { gameId, playerId } = req.params;
    
    const removed = gameStateManager.maybeRemovePlayer(gameId, playerId);
    
    if (!removed) {
      return respondFailure(res, 404, 'Failed to remove player');
    }

    const game = gameStateManager.maybeGetGame(gameId);
    
    if (game) {
      broadcastToGame(gameId, 'playerLeft', { playerId, game: toGameStateClient(game) });
    } else {
      broadcastToAll('gameDeleted', { gameId });
    }

    return respondSuccessWithData(res, 200, { removed: true });
  });

  router.delete('/games/:gameId', (req, res) => {
    const { gameId } = req.params;
    
    const deleted = gameStateManager.maybeDeleteGame(gameId);
    
    if (!deleted) {
      return respondGameNotFound(res, null);
    }

    broadcastToAll('gameDeleted', { gameId });

    return respondSuccessWithData(res, 200, { deleted: true });
  });

  return router;
}