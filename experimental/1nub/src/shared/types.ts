import { Ctx } from 'boardgame.io';

export type PlayerID = string;
export type RoleId = string;
export type SeatNumber = number;

export interface NightActionSpec {
  uiPrompt?: {
    type: "choosePlayer" | "chooseCenter" | "noPrompt" | "choosePlayers";
    min?: number;
    max?: number;
    label?: string;
    extraFields?: any;
  };
  validator?: (G: GameState, ctx: Ctx, payload: any) => boolean;
  perform: (G: GameState, ctx: Ctx, payload: any) => void;
}

export interface RoleDefinition {
  id: RoleId;
  name: string;
  description?: string;
  nightAction?: NightActionSpec;
  onNightEnd?: (G: GameState, ctx: Ctx) => void;
  scoring?: (G: GameState, ctx: Ctx) => void;
  nightOrder: number; // Determines when this role acts during night
}

export interface PlayerState {
  id: PlayerID;
  seat: SeatNumber;
  role: RoleId;
  originalRole: RoleId;
  privateLog: string[];
  connected: boolean;
  hasActed?: boolean; // Track if player has performed their night action
}

export interface NightActionRecord {
  actor: PlayerID;
  roleId: RoleId;
  payload: any;
  timestamp: number;
}

export interface GameReveal {
  winners: PlayerID[];
  endSummary: {
    finalRoles: Record<PlayerID, RoleId>;
    originalRoles: Record<PlayerID, RoleId>;
    votes: Record<PlayerID, PlayerID>;
    eliminatedPlayers: PlayerID[];
    winCondition: string;
  };
}

export interface GameState {
  players: Record<PlayerID, PlayerState>;
  center: RoleId[]; // 3 center cards
  votes: Record<PlayerID, PlayerID>; // vote from -> vote to
  nightActions: NightActionRecord[];
  revealed: GameReveal | null;
  nightStep: number; // Current step in night phase
  currentNightRole: RoleId | null; // Which role is currently acting
  gameOptions: {
    enabledRoles: RoleId[];
    timeLimit?: number; // Time limit for phases in seconds
    autoAdvance?: boolean; // Automatically advance phases
  };
  seenCenterCards?: Record<PlayerID, number[]>; // Track which center cards each player has seen
}

export interface GameOptions {
  enabledRoles?: RoleId[];
  timeLimit?: number;
  autoAdvance?: boolean;
}

// Move payloads
export interface StartGamePayload {
  options?: GameOptions;
}

export interface SeatPlayerPayload {
  seat: SeatNumber;
}

export interface ExecuteNightActionPayload {
  target?: PlayerID | PlayerID[];
  centerCard?: number;
  extra?: any;
}

export interface CastVotePayload {
  target: PlayerID;
}

// UI-specific types
export interface GamePhases {
  lobby: 'lobby';
  night: 'night';
  day: 'day';
  voting: 'voting';
  reveal: 'reveal';
  end: 'end';
}

export const GAME_PHASES: GamePhases = {
  lobby: 'lobby',
  night: 'night',
  day: 'day',
  voting: 'voting',
  reveal: 'reveal',
  end: 'end'
};