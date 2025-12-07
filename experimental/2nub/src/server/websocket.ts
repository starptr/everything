import { Server, Socket } from 'socket.io';
import { gameStateManager } from './gameState';
import { ClientToServerEvents, ServerToClientEvents } from '../types';

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
      const registered = gameStateManager.registerPlayerSocket(gameId, playerId, socket.id);
      
      if (registered) {
        // Store player info on socket for easier access
        socket.gameId = gameId;
        socket.playerId = playerId;
        
        // Join the game room
        socket.join(gameId);
        
        // Broadcast updated game state to all players in the room
        const gameState = gameStateManager.getGame(gameId);
        if (gameState) {
          broadcastToGame(gameId, 'gameState', gameState);
        }
        
        console.log(`Player ${playerId} authenticated and joined room ${gameId}`);
      } else {
        console.error(`Failed to authenticate player ${playerId} for game ${gameId}`);
        socket.emit('error', { error: 'Authentication failed' });
      }
    });

    socket.on('disconnect', () => {
      console.log('Socket.io client disconnected:', socket.id);
      
      // Use the socket registry to identify the disconnecting player
      const mapping = gameStateManager.unregisterSocket(socket.id);
      
      if (mapping) {
        // Leave the game room
        socket.leave(mapping.gameId);
        
        // Broadcast updated game state to remaining players in the room
        const gameState = gameStateManager.getGame(mapping.gameId);
        if (gameState) {
          broadcastToGame(mapping.gameId, 'gameState', gameState);
        }
        
        console.log(`Player ${mapping.playerId} disconnected from game ${mapping.gameId}`);
      }
    });

    socket.on('error', (error) => {
      console.error('Socket.io error:', error);
    });
  });
}

export function broadcastToGame(gameId: string, event: keyof ServerToClientEvents, data: any) {
  const io = global.io as Server<ClientToServerEvents, ServerToClientEvents>;
  if (io) {
    io.to(gameId).emit(event, data);
  }
}

export function broadcastToAll(event: keyof ServerToClientEvents, data: any) {
  const io = global.io as Server<ClientToServerEvents, ServerToClientEvents>;
  if (io) {
    io.emit(event, data);
  }
}