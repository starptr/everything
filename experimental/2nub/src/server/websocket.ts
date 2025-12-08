import { Server, Socket } from 'socket.io';
import { gameStateManager } from './gameState';
import { ClientToServerEvents, ServerToClientEvents, ServerToClientEventShapes, GameState, GameStateClient } from '../types';

// Helper function to convert GameState to GameStateClient (remove ID)
function toGameStateClient(gameState: GameState): GameStateClient {
  const { id, ...gameStateClient } = gameState;
  return gameStateClient;
}

interface ExtendedSocket extends Socket<ClientToServerEvents, ServerToClientEvents> {
  gameId?: string;
  playerId?: string;
}

export function setupSocketIO(io: Server<ClientToServerEvents, ServerToClientEvents>) {
  io.on('connection', (socket: ExtendedSocket) => {
    console.log('Socket.io client connected:', socket.id);
    
    socket.on('authenticatePlayer', (data) => {
      const { gameId, playerId } = data;
      console.log(`Authenticating player ${playerId} for game ${gameId} on socket ${socket.id}`);
      
      // Register the socket with the player
      const registered = gameStateManager.maybeRegisterPlayerSocket(gameId, playerId, socket.id);
      
      if (registered) {
        // Store player info on socket for easier access
        socket.gameId = gameId;
        socket.playerId = playerId;
        
        // Join the game room
        socket.join(gameId);
        
        // Broadcast updated game state to all players in the room
        const gameState = gameStateManager.maybeGetGame(gameId);
        if (gameState) {
          broadcastToGame(gameId, 'gameState', toGameStateClient(gameState));
        }
        
        console.log(`Player ${playerId} authenticated and joined room ${gameId}`);
      } else {
        console.error(`Failed to authenticate player ${playerId} for game ${gameId}`);
        socket.emit('error', { error: 'Authentication failed' });
      }
    });

    socket.on('updateRuleset', (data) => {
      const { gameId, ruleset } = data;
      console.log(`Updating ruleset for game ${gameId} from socket ${socket.id}`);
      
      // Verify the socket is authenticated for this game
      if (socket.gameId !== gameId) {
        console.error(`Socket ${socket.id} not authenticated for game ${gameId}`);
        socket.emit('error', { error: 'Not authenticated for this game' });
        return;
      }
      
      // Update the ruleset via game state manager
      const updatedGameState = gameStateManager.maybeUpdateRuleset(gameId, ruleset);
      
      if (updatedGameState) {
        // Broadcast updated game state to all players in the room
        broadcastToGame(gameId, 'gameState', toGameStateClient(updatedGameState));
        console.log(`Ruleset updated and broadcasted for game ${gameId}`);
      } else {
        console.error(`Failed to update ruleset for game ${gameId}`);
        socket.emit('error', { error: 'Failed to update ruleset' });
      }
    });

    socket.on('startGame', async (data) => {
      const { gameId } = data;

      // Verify the socket is authenticated for this game
      if (socket.gameId !== gameId) {
        console.error(`Socket ${socket.id} not authenticated for game ${gameId}`);
        socket.emit('error', { error: 'Not authenticated for this game' });
        return;
      }

      console.log(`Starting game ${gameId} from socket ${socket.id}`);

      // Start the game via game state manager
      const startedGameState = await gameStateManager.maybeStartGame(gameId);
      
      if (startedGameState) {
        // Broadcast updated game state to all players in the room
        broadcastToGame(gameId, 'gameState', toGameStateClient(startedGameState));
        console.log(`Game ${gameId} started and broadcasted`);
      } else {
        console.error(`Failed to start game ${gameId}`);
        socket.emit('error', { error: 'Failed to start game' });
      }
    });

    socket.on('disconnect', () => {
      console.log('Socket.io client disconnected:', socket.id);
      
      // Use the socket registry to identify the disconnecting player
      const mapping = gameStateManager.maybeUnregisterSocket(socket.id);
      
      if (mapping) {
        // Leave the game room
        socket.leave(mapping.gameId);
        
        // Broadcast updated game state to remaining players in the room
        const gameState = gameStateManager.maybeGetGame(mapping.gameId);
        if (gameState) {
          broadcastToGame(mapping.gameId, 'gameState', toGameStateClient(gameState));
        }
        
        console.log(`Player ${mapping.playerId} disconnected from game ${mapping.gameId}`);
      }
    });

    socket.on('error', (error) => {
      console.error('Socket.io error:', error);
    });
  });
}

export function broadcastToGame<K extends keyof ServerToClientEventShapes>(gameId: string, event: K, data: ServerToClientEventShapes[K]) {
  const io = global.io as Server<ClientToServerEvents, ServerToClientEvents>;
  if (io) {
    // @ts-expect-error -- TS cannot infer that event is a valid key here
    io.to(gameId).emit(event, data);
  }
}

export function broadcastToAll<K extends keyof ServerToClientEventShapes>(event: K, data: ServerToClientEventShapes[K]) {
  const io = global.io as Server<ClientToServerEvents, ServerToClientEvents>;
  if (io) {
    // @ts-expect-error -- TS cannot infer that event is a valid key here
    io.emit(event, data);
  }
}