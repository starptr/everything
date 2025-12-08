export const ROLES = [
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
  "50/50 duo cop"
] as const;
export type RoleId = typeof ROLES[number];

export type SpecialRules = {
  maybeAllTanners: {
    enabled: boolean;
    probability: number;
  };
};

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
  ruleset: {
    roleOrder: RoleId[];
    special: SpecialRules;
  }
};

export interface StateNight {
  state: 'night';
  playerData: Record<Player["id"], PlayerState>;
  centerCards: RoleId[];
  ruleset: StateLobby["ruleset"];
}

export interface StateDay {
  state: 'day';
  playerData: StateNight["playerData"];
  centerCards: StateNight["centerCards"];
  ruleset: StateNight["ruleset"];
}

export interface StateVoting {
  state: 'voting';
  votes: Record<Player["id"], Player["id"]>;
  playerData: StateDay["playerData"];
  centerCards: StateDay["centerCards"];
  ruleset: StateDay["ruleset"];
}

export interface StateFinished {
  state: 'finished';
  winnerRoleIds: RoleId[];
  votes: StateVoting["votes"];
  playerData: StateVoting["playerData"];
  centerCards: StateVoting["centerCards"];
  ruleset: StateVoting["ruleset"];
}

// Client-side game state without ID (pure game data)
export type GameStateClient = {
  // Set on construction only
  readonly createdAt: Date;

  name: string;
  lastActivity: Date;
  gameLog: string[];

  players: Player[];
  state: StateLobby | StateNight | StateDay | StateVoting | StateFinished;
}

// Server-side game state with ID for storage/routing
export type GameState = GameStateClient & {
  readonly id: string;
}

export interface CreateGameRequest {
  name: string;
}

export interface JoinGameRequest {
  gameId: GameState["id"];
  playerName: Player["name"];
}

export interface RejoinGameRequest {
  gameId: GameState["id"];
  playerId: Player["id"];
}

export interface ServerToClientEventShapes {
  gameState: GameStateClient;
  playerJoined: { game: GameStateClient; player: Player };
  playerLeft: { game: GameStateClient; playerId: string };
  gameCreated: GameState; // Keep full GameState for game list updates
  gameDeleted: { gameId: string };
  error: { error: string };
}

// Socket.io event interfaces
export type ServerToClientEvents = {
  [K in keyof ServerToClientEventShapes]: (data: ServerToClientEventShapes[K]) => void;
}

export interface ClientToServerEvents {
  authenticatePlayer: (data: { gameId: string; playerId: string }) => void;
  updateRuleset: (data: { gameId: string; ruleset: StateLobby["ruleset"] }) => void;
}

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
}