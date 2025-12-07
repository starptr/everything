const ROLES = [
  //"copycat",
  //"doppelganger",
  "werewolf",
  //"minion",
  "seer",
  "robber",
  "troublemaker",
  "villager",
  "tanner",
  "hunter",
  "mason",
  "insomniac",
] as const;
export type RoleId = typeof ROLES[number];

export interface Player {
  id: string;
  name: string;
  connected: boolean;
}

export interface PlayerState {
  readonly originalRoleId: RoleId;
  currentRoleId: RoleId;
  playerLog: string[];
}

export interface StateLobby {
  state: 'lobby';
};

export interface StateNight {
  state: 'night';
  playerData: Record<Player["id"], PlayerState>;
  centerCards: RoleId[];
}

export interface StateDay {
  state: 'day';
  playerData: StateNight["playerData"];
  centerCards: StateNight["centerCards"];
}

export interface StateVoting {
  state: 'voting';
  votes: Record<Player["id"], Player["id"]>;
  playerData: StateDay["playerData"];
  centerCards: StateDay["centerCards"];
}

export interface StateFinished {
  state: 'finished';
  winnerRoleIds: RoleId[];
  votes: StateVoting["votes"];
  playerData: StateVoting["playerData"];
  centerCards: StateVoting["centerCards"];
}

export type GameState = {
  // Set on construction only
  readonly id: string;
  readonly createdAt: Date;

  name: string;
  lastActivity: Date;
  gameLog: string[];

  players: Player[];
  roleOrder: RoleId[];
  state: StateLobby | StateNight | StateDay | StateVoting | StateFinished;
}

export interface CreateGameRequest {
  name: string;
}

export interface JoinGameRequest {
  gameId: GameState["id"];
  playerName?: Player["name"];
  existingPlayerId?: Player["id"];
}

export interface ServerToClientEventShapes {
  gameState: GameState;
  playerJoined: { game: GameState; player: Player };
  playerLeft: { game: GameState; playerId: string };
  gameCreated: GameState;
  gameDeleted: { gameId: string };
  error: { error: string };
}

// Socket.io event interfaces
export type ServerToClientEvents = {
  [K in keyof ServerToClientEventShapes]: (data: ServerToClientEventShapes[K]) => void;
}

export interface ClientToServerEvents {
  authenticatePlayer: (data: { gameId: string; playerId: string }) => void;
}

// Legacy WebSocket message interface (can be removed if not used elsewhere)
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