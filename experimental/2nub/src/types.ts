export interface Player {
  id: string;
  name: string;
  seat: number;
  connected: boolean;
}

export interface GameState {
  id: string;
  name: string;
  players: Record<string, Player>;
  maxPlayers: number;
  status: 'waiting' | 'playing' | 'finished';
  createdAt: Date;
  lastActivity: Date;
}

export interface CreateGameRequest {
  name: string;
  maxPlayers: number;
}

export interface JoinGameRequest {
  gameId: string;
  playerName: string;
}

export interface WebSocketMessage {
  type: 'gameState' | 'playerJoined' | 'playerLeft' | 'gameCreated' | 'gameDeleted' | 'error';
  data: any;
  gameId?: string;
}

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
}