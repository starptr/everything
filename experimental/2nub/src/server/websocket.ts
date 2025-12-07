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

    socket.on('joinGame', ({ gameId, playerId }) => {
      if (gameId && playerId) {
        socket.gameId = gameId;
        socket.playerId = playerId;
        
        // Join the game room
        socket.join(gameId);
        
        // Update player connection status
        gameStateManager.updatePlayerConnection(gameId, playerId, true);
        
        // Broadcast updated game state to all players in the room
        const gameState = gameStateManager.getGame(gameId);
        if (gameState) {
          broadcastToGame(gameId, 'gameState', gameState);
        }
        
        console.log(`Player ${playerId} joined game ${gameId}`);
      }
    });

    socket.on('forceDisconnectPlayer', ({ gameId, playerId }) => {
      if (gameId && playerId) {
        // Update player connection status to disconnected
        gameStateManager.updatePlayerConnection(gameId, playerId, false);
        
        // Broadcast updated game state to all players in the room
        const gameState = gameStateManager.getGame(gameId);
        if (gameState) {
          broadcastToGame(gameId, 'gameState', gameState);
        }
        
        console.log(`Player ${playerId} was force disconnected from game ${gameId}`);
      }
    });

    socket.on('disconnect', () => {
      console.log('Socket.io client disconnected:', socket.id);
      
      if (socket.gameId && socket.playerId) {
        // Update player connection status
        gameStateManager.updatePlayerConnection(socket.gameId, socket.playerId, false);
        
        // Broadcast updated game state to ALL players in the room (including the disconnecting one)
        const gameState = gameStateManager.getGame(socket.gameId);
        if (gameState) {
          broadcastToGame(socket.gameId, 'gameState', gameState);
        }
        
        console.log(`Player ${socket.playerId} left game ${socket.gameId}`);
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