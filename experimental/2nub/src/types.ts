export interface Player {
  id: string;
  name: string;
  connected: boolean;
}

export interface GameState {
  id: string;
  name: string;
  players: Player[];
  status: 'waiting' | 'playing' | 'finished';
  createdAt: Date;
  lastActivity: Date;
}

export interface CreateGameRequest {
  name: string;
}

export interface JoinGameRequest {
  gameId: GameState["id"];
  playerName: Player["name"];
}

export interface WebSocketMessage {
  type: 'gameState' | 'playerJoined' | 'playerLeft' | 'gameCreated' | 'gameDeleted' | 'error';
  data: any;
  gameId?: GameState["id"];
}

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
}