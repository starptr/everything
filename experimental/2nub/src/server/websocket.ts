import { WebSocketServer, WebSocket } from 'ws';
import { gameStateManager } from './gameState';
import { WebSocketMessage } from '../types';

interface ExtendedWebSocket extends WebSocket {
  gameId?: string;
  playerId?: string;
}

const gameConnections: Map<string, Set<ExtendedWebSocket>> = new Map();

export function setupWebSocket(wss: WebSocketServer) {
  wss.on('connection', (ws: ExtendedWebSocket) => {
    console.log('WebSocket client connected');

    ws.on('message', (message: Buffer) => {
      try {
        const data = JSON.parse(message.toString());
        handleWebSocketMessage(ws, data);
      } catch (error) {
        console.error('Error parsing WebSocket message:', error);
        sendError(ws, 'Invalid message format');
      }
    });

    ws.on('close', () => {
      console.log('WebSocket client disconnected');
      if (ws.gameId && ws.playerId) {
        gameStateManager.updatePlayerConnection(ws.gameId, ws.playerId, false);
        broadcastToGame(ws.gameId, {
          type: 'gameState',
          data: gameStateManager.getGame(ws.gameId),
          gameId: ws.gameId
        });
        removeConnectionFromGame(ws.gameId, ws);
      }
    });

    ws.on('error', (error) => {
      console.error('WebSocket error:', error);
    });
  });
}

function handleWebSocketMessage(ws: ExtendedWebSocket, message: any) {
  switch (message.type) {
    case 'joinGame':
      const { gameId, playerId } = message.data;
      if (gameId && playerId) {
        ws.gameId = gameId;
        ws.playerId = playerId;
        addConnectionToGame(gameId, ws);
        gameStateManager.updatePlayerConnection(gameId, playerId, true);
        
        broadcastToGame(gameId, {
          type: 'gameState',
          data: gameStateManager.getGame(gameId),
          gameId
        });
      }
      break;
      
    default:
      sendError(ws, 'Unknown message type');
  }
}

function addConnectionToGame(gameId: string, ws: ExtendedWebSocket) {
  if (!gameConnections.has(gameId)) {
    gameConnections.set(gameId, new Set());
  }
  gameConnections.get(gameId)!.add(ws);
}

function removeConnectionFromGame(gameId: string, ws: ExtendedWebSocket) {
  const connections = gameConnections.get(gameId);
  if (connections) {
    connections.delete(ws);
    if (connections.size === 0) {
      gameConnections.delete(gameId);
    }
  }
}

export function broadcastToGame(gameId: string, message: WebSocketMessage) {
  const connections = gameConnections.get(gameId);
  if (!connections) return;

  const messageStr = JSON.stringify(message);
  connections.forEach((ws) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(messageStr);
    }
  });
}

export function broadcastToAll(message: WebSocketMessage) {
  gameConnections.forEach((connections) => {
    connections.forEach((ws) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(message));
      }
    });
  });
}

function sendError(ws: WebSocket, error: string) {
  ws.send(JSON.stringify({
    type: 'error',
    data: { error }
  }));
}