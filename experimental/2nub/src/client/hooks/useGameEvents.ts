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

const createEventHandler = <T>(handler: ((data: T) => void) | undefined, eventName: string) => {
  if (!handler) return undefined;
  
  return (data: T) => {
    try {
      handler(data);
    } catch (error) {
      console.error(`Error handling ${eventName} event:`, error);
    }
  };
};

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

    const eventHandlers = {
      gameState: createEventHandler(onGameState, 'gameState'),
      playerJoined: createEventHandler(onPlayerJoined, 'playerJoined'),
      playerLeft: createEventHandler(onPlayerLeft, 'playerLeft'),
      gameCreated: createEventHandler(onGameCreated, 'gameCreated'),
      gameDeleted: createEventHandler(onGameDeleted, 'gameDeleted'),
      error: createEventHandler(onServerError, 'error')
    };

    Object.entries(eventHandlers).forEach(([event, handler]) => {
      if (handler) {
        socket.on(event, handler);
      }
    });

    return () => {
      Object.entries(eventHandlers).forEach(([event, handler]) => {
        if (handler) {
          socket.off(event, handler);
        }
      });
    };
  }, [socket, onGameState, onPlayerJoined, onPlayerLeft, onGameCreated, onGameDeleted, onServerError]);

  return {
    isConnected,
    joinGame,
    connect,
    disconnect,
  };
}