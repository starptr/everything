import { useState, useEffect, useRef, useCallback } from 'react';
import { io, Socket } from 'socket.io-client';
import { API_BASE_URL } from '../config/api';

interface UseWebSocketOptions {
  onConnect: () => void;
  onDisconnect: () => void;
  onConnectionError: (error: any) => void;
}

interface UseWebSocketReturn {
  isConnected: boolean;
  socket: Socket | null;
  connect: () => void;
  disconnect: () => void;
}

export function useWebSocket(options: UseWebSocketOptions): UseWebSocketReturn {
  const [isConnected, setIsConnected] = useState(false);
  const socketRef = useRef<Socket | null>(null);
  const { onConnect, onDisconnect, onConnectionError } = options;

  const disconnect = useCallback(() => {
    socketRef.current?.disconnect();
    socketRef.current = null;
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
      onConnect();
    });

    socketRef.current.on('disconnect', () => {
      setIsConnected(false);
      onDisconnect();
    });

    socketRef.current.on('connect_error', (error) => {
      console.error('Socket.io connection error:', error);
      onConnectionError(error);
    });
  }, [onConnect, onDisconnect, onConnectionError]);

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
  };
}