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
  "50/50 duo cop",
  "50/50 duo cop(sane)",
  "50/50 duo cop(insane)",
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
  players: Player[];
};

export interface StateRoleAssignment {
  state: 'roleAssignment';
  // Array of player IDs in order of wake-up, grouped by simultaneous wake-ups
  playerIdsByWakeupOrder: Player["id"][][];
  playerData: Record<Player["id"], PlayerState>;
  centerCards: RoleId[];
  ruleset: StateLobby["ruleset"];
  playerConfirmations: Record<Player["id"], boolean>;
  players: StateLobby["players"];
}

export interface StateNight {
  state: 'night';
  playerIdsByWakeupOrder: StateRoleAssignment["playerIdsByWakeupOrder"];
  playerData: StateRoleAssignment["playerData"];
  centerCards: StateRoleAssignment["centerCards"];
  ruleset: StateRoleAssignment["ruleset"];
  turn: number;
  endedTurn: {
    [playerId: Player["id"]]: boolean;
  }[];
  players: StateRoleAssignment["players"];
}

export interface StateDay {
  state: 'day';
  playerData: StateNight["playerData"];
  centerCards: StateNight["centerCards"];
  ruleset: StateNight["ruleset"];
  players: StateNight["players"];
}

export interface StateVoting {
  state: 'voting';
  votes: Record<Player["id"], Player["id"]>;
  playerData: StateDay["playerData"];
  centerCards: StateDay["centerCards"];
  ruleset: StateDay["ruleset"];
  players: StateDay["players"];
}

export interface StateFinished {
  state: 'finished';
  winnerRoleIds: RoleId[];
  votes: StateVoting["votes"];
  playerData: StateVoting["playerData"];
  centerCards: StateVoting["centerCards"];
  ruleset: StateVoting["ruleset"];
  players: StateVoting["players"];
}

// Client-side game state without ID (pure game data)
export type GameStateClient = {
  // Set on construction only
  readonly createdAt: Date;

  name: string;
  gameLog: string[];

  state: StateLobby | StateRoleAssignment | StateNight | StateDay | StateVoting | StateFinished;
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
  startGame: (data: { gameId: string }) => void;
  confirmRoleAssignment: (data: { gameId: string; playerId: string }) => void;
  endTurn: (data: { gameId: string; playerId: string}) => void;
}

export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
}