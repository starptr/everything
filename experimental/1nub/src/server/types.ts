import { Ctx } from 'boardgame.io';

export type PlayerID = string;
export type RoleId = string;

export interface NightActionSpec {
  uiPrompt?: {
    type: "choosePlayer" | "chooseCenter" | "noPrompt" | "choosePlayers";
    min?: number;
    max?: number;
    label?: string;
    extraFields?: any;
  };
  validator?: (G: GState, ctx: Ctx, payload: any) => boolean;
  perform: (G: GState, ctx: Ctx, payload: any) => void;
}

export interface RoleDefinition {
  id: RoleId;
  name: string;
  description?: string;
  team: "werewolf" | "village" | "special";
  nightAction?: NightActionSpec;
  onNightEnd?: (G: GState, ctx: Ctx) => void;
  scoring?: (G: GState, ctx: Ctx) => void;
}

export interface PlayerState {
  id: PlayerID;
  name: string;
  seat: number;
  role: RoleId;
  originalRole: RoleId;
  privateLog: string[];
  connected: boolean;
}

export interface NightActionRecord {
  actor: PlayerID;
  roleId: RoleId;
  payload: any;
  timestamp: number;
}

export interface GameOptions {
  enabledRoles: RoleId[];
  nightTimeLimit?: number;
  dayTimeLimit?: number;
  votingTimeLimit?: number;
}

export interface GState {
  players: Record<PlayerID, PlayerState>;
  secret: {
    center: RoleId[];
    nightActions: NightActionRecord[];
    currentNightStep: number;
  },
  votes: Record<PlayerID, PlayerID>;
  nightOrder: RoleId[];
  gameOptions: GameOptions;
  revealed: {
    winners: PlayerID[];
    endSummary: {
      finalRoles: Record<PlayerID, RoleId>;
      voteTally: Record<PlayerID, number>;
      eliminatedPlayers: PlayerID[];
      winCondition: string;
    };
  } | null;
  timers: {
    phaseStartTime?: number;
    phaseTimeLimit?: number;
  };
}

export interface MovePayload {
  [key: string]: any;
}

export interface ExecuteNightActionPayload extends MovePayload {
  target?: PlayerID;
  targets?: PlayerID[];
  centerIndex?: number;
  centerIndices?: number[];
}

export interface CastVotePayload extends MovePayload {
  target: PlayerID;
}

export interface SeatPlayerPayload extends MovePayload {
  seat: number;
  playerName: string;
}

export interface StartGamePayload extends MovePayload {
  gameOptions: GameOptions;
}

export const DEFAULT_ROLES: RoleId[] = [
  "werewolf",
  "werewolf", 
  "seer",
  "robber",
  "troublemaker",
  "villager",
  "villager",
  "villager"
];

export const NIGHT_ORDER: RoleId[] = [
  "werewolf",
  "seer", 
  "robber",
  "troublemaker"
];