import { useEffect, useCallback } from 'react';
import { useWebSocket } from './useWebSocket';
import { GameState, Player, ServerToClientEvents } from '../../types';

interface UseGameEventsOptions {
  onGameState?: (gameState: GameState) => void;
  onPlayerJoined?: (data: { game: GameState; player: Player }) => void;
  onPlayerLeft?: (data: { game: GameState; playerId: string }) => void;
  onGameCreated?: (game: GameState) => void;
  onGameDeleted?: (data: { gameId: string }) => void;
  onServerError?: (data: { error: string }) => void;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onConnectionError?: (error: any) => void;
}

interface UseGameEventsReturn {
  isConnected: boolean;
  joinGame: (gameId: string, playerId: string) => void;
  connect: () => void;
  disconnect: () => void;
}

export function useGameEvents(options: UseGameEventsOptions = {}): UseGameEventsReturn {
  const {
    onGameState,
    onPlayerJoined,
    onPlayerLeft,
    onGameCreated,
    onGameDeleted,
    onServerError,
    onConnect,
    onDisconnect,
    onConnectionError
  } = options;

  const { isConnected, socket, connect, disconnect } = useWebSocket({
    onConnect,
    onDisconnect,
    onConnectionError
  });

  const joinGame = useCallback((gameId: string, playerId: string) => {
    if (socket?.connected) {
      socket.emit('joinGame', { gameId, playerId });
    } else {
      console.warn('Socket not connected. Cannot join game.');
    }
  }, [socket]);

  useEffect(() => {
    if (!socket) return;

    // Handle gameState events
    const handleGameState = (gameState: GameState) => {
      try {
        onGameState?.(gameState);
      } catch (error) {
        console.error('Error handling gameState event:', error);
      }
    };

    // Handle playerJoined events  
    const handlePlayerJoined = (data: { game: GameState; player: Player }) => {
      try {
        onPlayerJoined?.(data);
      } catch (error) {
        console.error('Error handling playerJoined event:', error);
      }
    };

    // Handle playerLeft events
    const handlePlayerLeft = (data: { game: GameState; playerId: string }) => {
      try {
        onPlayerLeft?.(data);
      } catch (error) {
        console.error('Error handling playerLeft event:', error);
      }
    };

    // Handle gameCreated events
    const handleGameCreated = (game: GameState) => {
      try {
        onGameCreated?.(game);
      } catch (error) {
        console.error('Error handling gameCreated event:', error);
      }
    };

    // Handle gameDeleted events
    const handleGameDeleted = (data: { gameId: string }) => {
      try {
        onGameDeleted?.(data);
      } catch (error) {
        console.error('Error handling gameDeleted event:', error);
      }
    };

    // Handle server error events
    const handleServerError = (data: { error: string }) => {
      try {
        onServerError?.(data);
      } catch (error) {
        console.error('Error handling server error event:', error);
      }
    };

    // Register all event listeners defensively
    socket.on('gameState', handleGameState);
    socket.on('playerJoined', handlePlayerJoined);
    socket.on('playerLeft', handlePlayerLeft);
    socket.on('gameCreated', handleGameCreated);
    socket.on('gameDeleted', handleGameDeleted);
    socket.on('error', handleServerError);

    // Cleanup function to remove all event listeners
    return () => {
      socket.off('gameState', handleGameState);
      socket.off('playerJoined', handlePlayerJoined);
      socket.off('playerLeft', handlePlayerLeft);
      socket.off('gameCreated', handleGameCreated);
      socket.off('gameDeleted', handleGameDeleted);
      socket.off('error', handleServerError);
    };
  }, [socket, onGameState, onPlayerJoined, onPlayerLeft, onGameCreated, onGameDeleted, onServerError]);

  return {
    isConnected,
    joinGame,
    connect,
    disconnect,
  };
}