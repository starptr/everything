import { useState, useEffect, useRef, useCallback } from 'react';
import { io, Socket } from 'socket.io-client';
import { API_BASE_URL } from '../config/api';

interface UseWebSocketOptions {
  onGameState?: (gameState: any) => void;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onError?: (error: any) => void;
}

interface UseWebSocketReturn {
  isConnected: boolean;
  joinGame: (gameId: string, playerId: string) => void;
  connect: () => void;
  disconnect: () => void;
}

export function useWebSocket(options: UseWebSocketOptions = {}): UseWebSocketReturn {
  const [isConnected, setIsConnected] = useState(false);
  const socketRef = useRef<Socket | null>(null);
  const { onGameState, onConnect, onDisconnect, onError } = options;

  const connect = useCallback(() => {
    if (socketRef.current?.connected) {
      return;
    }

    socketRef.current = io(API_BASE_URL, {
      transports: ['websocket', 'polling']
    });

    socketRef.current.on('connect', () => {
      setIsConnected(true);
      onConnect?.();
    });

    socketRef.current.on('gameState', (gameState) => {
      onGameState?.(gameState);
    });

    socketRef.current.on('disconnect', () => {
      setIsConnected(false);
      onDisconnect?.();
    });

    socketRef.current.on('connect_error', (error) => {
      console.error('Socket.io connection error:', error);
      onError?.(error);
    });

    socketRef.current.on('error', (error) => {
      console.error('Socket.io error:', error);
      onError?.(error);
    });
  }, [onGameState, onConnect, onDisconnect, onError]);

  const disconnect = useCallback(() => {
    socketRef.current?.disconnect();
    socketRef.current = null;
    setIsConnected(false);
  }, []);

  const joinGame = useCallback((gameId: string, playerId: string) => {
    if (socketRef.current?.connected) {
      socketRef.current.emit('joinGame', { gameId, playerId });
    } else {
      console.warn('Socket not connected. Cannot join game.');
    }
  }, []);

  useEffect(() => {
    return () => {
      disconnect();
    };
  }, [disconnect]);

  return {
    isConnected,
    joinGame,
    connect,
    disconnect,
  };
}