import { useState, useEffect, useRef, useCallback } from 'react';
import { io, Socket } from 'socket.io-client';
import { API_BASE_URL } from '../config/api';

interface UseWebSocketOptions {
  onConnect: () => void;
  onDisconnect: () => void;
  onConnectionError: (error: any) => void;
  gameId?: string;
  playerId?: string;
}

interface UseWebSocketReturn {
  isConnected: boolean;
  socket: Socket | null;
  connect: () => void;
  disconnect: () => void;
  authenticatePlayer: (gameId: string, playerId: string) => void;
}

export function useWebSocket(options: UseWebSocketOptions): UseWebSocketReturn {
  const [isConnected, setIsConnected] = useState(false);
  const socketRef = useRef<Socket | null>(null);
  const authenticatedRef = useRef<string | null>(null); // Track current authenticated player
  const authCooldownRef = useRef<number>(0); // Prevent rapid re-auth attempts
  const gameIdRef = useRef<string | undefined>(options.gameId);
  const playerIdRef = useRef<string | undefined>(options.playerId);
  const { onConnect, onDisconnect, onConnectionError, gameId, playerId } = options;

  // Update refs when props change
  gameIdRef.current = gameId;
  playerIdRef.current = playerId;

  const disconnect = useCallback(() => {
    socketRef.current?.disconnect();
    socketRef.current = null;
    authenticatedRef.current = null; // Clear authentication state
    setIsConnected(false);
  }, []);

  const connect = useCallback(() => {
    if (socketRef.current?.connected) {
      return;
    }

    socketRef.current = io(API_BASE_URL, {
      transports: ['websocket', 'polling']
    });

    socketRef.current.on('connect', () => {
      setIsConnected(true);
      authenticatedRef.current = null; // Reset auth state on new connection
      
      // Auto-authenticate if we have player credentials and haven't authenticated yet
      if (gameIdRef.current && playerIdRef.current && socketRef.current) {
        const authKey = `${gameIdRef.current}:${playerIdRef.current}`;
        const now = Date.now();
        
        // Check cooldown (prevent auth within 1 second)
        if (authCooldownRef.current && now - authCooldownRef.current < 1000) {
          console.log('Authentication skipped due to cooldown');
          return;
        }
        
        console.log(`Auto-authenticating player ${playerIdRef.current} for game ${gameIdRef.current}`);
        socketRef.current.emit('authenticatePlayer', { gameId: gameIdRef.current, playerId: playerIdRef.current });
        authenticatedRef.current = authKey;
        authCooldownRef.current = now;
      }
      
      onConnect();
    });

    socketRef.current.on('disconnect', () => {
      setIsConnected(false);
      authenticatedRef.current = null; // Clear auth state on disconnect
      onDisconnect();
    });

    socketRef.current.on('connect_error', (error) => {
      console.error('Socket.io connection error:', error);
      onConnectionError(error);
    });
  }, [onConnect, onDisconnect, onConnectionError]);

  const authenticatePlayer = useCallback((gameId: string, playerId: string) => {
    if (socketRef.current && isConnected) {
      const authKey = `${gameId}:${playerId}`;
      const now = Date.now();
      
      // Check if already authenticated for this player/game
      if (authenticatedRef.current === authKey) {
        console.log('Player already authenticated, skipping');
        return;
      }
      
      // Check cooldown
      if (authCooldownRef.current && now - authCooldownRef.current < 1000) {
        console.log('Authentication skipped due to cooldown');
        return;
      }
      
      console.log(`Manually authenticating player ${playerId} for game ${gameId}`);
      socketRef.current.emit('authenticatePlayer', { gameId, playerId });
      authenticatedRef.current = authKey;
      authCooldownRef.current = now;
    }
  }, [isConnected]);

  // Handle authentication when gameId/playerId change while connected
  useEffect(() => {
    if (isConnected && gameId && playerId) {
      authenticatePlayer(gameId, playerId);
    }
  }, [gameId, playerId, isConnected, authenticatePlayer]);

  useEffect(() => {
    return () => {
      socketRef.current?.disconnect();
      socketRef.current = null;
    };
  }, []);

  return {
    isConnected,
    socket: socketRef.current,
    connect,
    disconnect,
    authenticatePlayer,
  };
}