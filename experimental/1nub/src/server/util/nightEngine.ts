import { GState, PlayerID, RoleId, NIGHT_ORDER } from "../types";
import { Ctx } from "boardgame.io";
import { getRoleDefinition } from "../roles";

export function initializeNight(G: GState, ctx: Ctx): void {
  G.currentNightStep = 0;
  G.nightOrder = [...NIGHT_ORDER];
  G.nightActions = [];
  G.timers.phaseStartTime = Date.now();
}

export function getCurrentNightRole(G: GState): RoleId | null {
  if (G.currentNightStep >= G.nightOrder.length) {
    return null;
  }
  return G.nightOrder[G.currentNightStep];
}

export function getActivePlayersForRole(G: GState, roleId: RoleId): PlayerID[] {
  return Object.values(G.players)
    .filter(player => player.originalRole === roleId)
    .map(player => player.id);
}

export function canPlayerAct(G: GState, playerID: PlayerID, roleId: RoleId): boolean {
  const player = G.players[playerID];
  if (!player) return false;

  const currentRole = getCurrentNightRole(G);
  if (currentRole !== roleId) return false;

  const alreadyActed = G.nightActions.some(action => action.actor === playerID);
  return !alreadyActed;
}

export function executeNightAction(
  G: GState, 
  ctx: Ctx, 
  playerID: PlayerID, 
  roleId: RoleId, 
  payload: any
): void {
  const roleDef = getRoleDefinition(roleId);
  
  if (!roleDef.nightAction) {
    throw new Error(`Role ${roleId} has no night action`);
  }

  if (!canPlayerAct(G, playerID, roleId)) {
    throw new Error(`Player ${playerID} cannot act as ${roleId} right now`);
  }

  if (roleDef.nightAction.validator) {
    if (!roleDef.nightAction.validator(G, ctx, payload)) {
      throw new Error("Invalid action payload");
    }
  }

  roleDef.nightAction.perform(G, ctx, { actor: playerID, ...payload });

  G.nightActions.push({
    actor: playerID,
    roleId,
    payload,
    timestamp: Date.now()
  });
}

export function canAdvanceNightStep(G: GState): boolean {
  const currentRole = getCurrentNightRole(G);
  if (!currentRole) return true;

  const activePlayers = getActivePlayersForRole(G, currentRole);
  if (activePlayers.length === 0) return true;

  const actedPlayers = G.nightActions
    .filter(action => action.roleId === currentRole)
    .map(action => action.actor);

  return activePlayers.every(playerId => actedPlayers.includes(playerId));
}

export function advanceNightStep(G: GState): boolean {
  if (!canAdvanceNightStep(G)) {
    return false;
  }

  G.currentNightStep++;
  return G.currentNightStep >= G.nightOrder.length;
}

export function finishNight(G: GState, ctx: Ctx): void {
  for (const roleId of G.nightOrder) {
    const roleDef = getRoleDefinition(roleId);
    if (roleDef.onNightEnd) {
      roleDef.onNightEnd(G, ctx);
    }
  }

  G.timers.phaseStartTime = Date.now();
  G.timers.phaseTimeLimit = G.gameOptions.dayTimeLimit;
}

export function isNightComplete(G: GState): boolean {
  return G.currentNightStep >= G.nightOrder.length && canAdvanceNightStep(G);
}