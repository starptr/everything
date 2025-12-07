import { useState, useEffect, useRef, useCallback } from 'react';
import { WebSocketMessage } from '../../types';
import { getWebSocketUrl } from '../config/api';

interface UseWebSocketOptions {
  onMessage?: (message: WebSocketMessage) => void;
  onOpen?: () => void;
  onClose?: () => void;
  onError?: (error: Event) => void;
}

interface UseWebSocketReturn {
  isConnected: boolean;
  sendMessage: (message: any) => void;
  connect: () => void;
  disconnect: () => void;
}

export function useWebSocket(options: UseWebSocketOptions = {}): UseWebSocketReturn {
  const [isConnected, setIsConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const { onMessage, onOpen, onClose, onError } = options;

  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      return;
    }

    const wsUrl = getWebSocketUrl();
    
    wsRef.current = new WebSocket(wsUrl);

    wsRef.current.onopen = () => {
      setIsConnected(true);
      onOpen?.();
    };

    wsRef.current.onmessage = (event) => {
      try {
        const message: WebSocketMessage = JSON.parse(event.data);
        onMessage?.(message);
      } catch (error) {
        console.error('Failed to parse WebSocket message:', error);
      }
    };

    wsRef.current.onclose = () => {
      setIsConnected(false);
      onClose?.();
    };

    wsRef.current.onerror = (error) => {
      console.error('WebSocket error:', error);
      onError?.(error);
    };
  }, [onMessage, onOpen, onClose, onError]);

  const disconnect = useCallback(() => {
    wsRef.current?.close();
    wsRef.current = null;
    setIsConnected(false);
  }, []);

  const sendMessage = useCallback((message: any) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(message));
    } else {
      console.warn('WebSocket not connected. Cannot send message.');
    }
  }, []);

  useEffect(() => {
    return () => {
      disconnect();
    };
  }, [disconnect]);

  return {
    isConnected,
    sendMessage,
    connect,
    disconnect,
  };
}