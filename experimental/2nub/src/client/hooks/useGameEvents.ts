import { useEffect, useCallback } from 'react';
import { useWebSocket } from './useWebSocket';
import { GameState, GameStateClient, Player, ServerToClientEvents } from '../../types';
import { buildApiUrl } from '../config/api';
import { sessionStorage } from '../utils/sessionStorage';

interface UseGameEventsOptions {
  onGameState: (gameState: GameStateClient) => void;
  onPlayerJoined: (data: { game: GameStateClient; player: Player }) => void;
  onPlayerLeft: (data: { game: GameStateClient; playerId: string }) => void;
  onGameCreated: (game: GameState) => void;
  onGameDeleted: (data: { gameId: string }) => void;
  onServerError: (data: { error: string }) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onConnectionError: (error: any) => void;
  gameId?: string;
  playerId?: string;
}

interface UseGameEventsReturn {
  isConnected: boolean;
  forceDisconnectPlayer: (gameId: string, playerId: string) => Promise<void>;
  connect: () => void;
  disconnect: () => void;
  authenticatePlayer: (gameId: string, playerId: string) => void;
}

const createEventHandler = <T>(eventName: string, handler: (data: T) => void) => {
  return (data: T) => {
    try {
      handler(data);
    } catch (error) {
      console.error(`Error handling ${eventName} event:`, error);
    }
  };
};

export function useGameEvents(options: UseGameEventsOptions): UseGameEventsReturn {
  const {
    onGameState,
    onPlayerJoined,
    onPlayerLeft,
    onGameCreated,
    onGameDeleted,
    onServerError,
    onConnect,
    onDisconnect,
    onConnectionError,
    gameId,
    playerId
  } = options;

  const { isConnected, socket, connect, disconnect, authenticatePlayer } = useWebSocket({
    onConnect,
    onDisconnect,
    onConnectionError,
    gameId,
    playerId
  });


  const forceDisconnectPlayer = useCallback(async (gameId: string, playerId: string) => {
    try {
      const response = await fetch(buildApiUrl(`api/games/${gameId}/players/${playerId}/disconnect`), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });
      const result = await response.json();
      if (!result.success) {
        console.error('Failed to force disconnect player:', result.error);
      }
    } catch (error) {
      console.error('Error force disconnecting player:', error);
    }
  }, []);


  useEffect(() => {
    if (!socket) return;

    // The type signature require that all keys of ServerToClientEvents are specified, and nothing more
    const eventHandlers: Record<keyof ServerToClientEvents, any> = {
      gameState: createEventHandler('gameState', onGameState),
      playerJoined: createEventHandler('playerJoined', onPlayerJoined),
      playerLeft: createEventHandler('playerLeft', onPlayerLeft),
      gameCreated: createEventHandler('gameCreated', onGameCreated),
      gameDeleted: createEventHandler('gameDeleted', onGameDeleted),
      error: createEventHandler('error', onServerError),
    };

    Object.entries(eventHandlers).forEach(([event, handler]) => {
      socket.on(event, handler);
    });

    return () => {
      Object.entries(eventHandlers).forEach(([event, handler]) => {
        socket.off(event, handler);
      });
    };
  }, [socket, onGameState, onPlayerJoined, onPlayerLeft, onGameCreated, onGameDeleted, onServerError]);

  return {
    isConnected,
    forceDisconnectPlayer,
    connect,
    disconnect,
    authenticatePlayer,
  };
}