import { Ctx } from 'boardgame.io';
import { GameState, PlayerID, GAME_PHASES } from '../../shared/types';

export function createPlayerView(G: GameState, ctx: Ctx, playerID: PlayerID): GameState {
  // Create a deep copy of the game state
  const playerG: GameState = JSON.parse(JSON.stringify(G));
  
  // If game hasn't started yet, return minimal info
  if (ctx.phase === GAME_PHASES.lobby) {
    return {
      ...playerG,
      // Hide center cards during lobby
      center: [],
      nightActions: [],
      revealed: null,
    };
  }

  // During the game, filter information based on what this player should see
  const currentPlayer = playerG.players[playerID];
  
  if (!currentPlayer) {
    // Spectator view - hide all private information
    return {
      ...playerG,
      players: Object.fromEntries(
        Object.entries(playerG.players).map(([id, player]) => [
          id,
          {
            ...player,
            role: ctx.phase === GAME_PHASES.reveal ? player.role : '',
            originalRole: ctx.phase === GAME_PHASES.reveal ? player.originalRole : '',
            privateLog: [], // Hide all private logs from spectators
          }
        ])
      ),
      center: playerG.center.map(() => ''), // Hide center card identities
      nightActions: [], // Hide night actions
    };
  }

  // Player view - show own information, hide others' secrets
  const filteredPlayers = Object.fromEntries(
    Object.entries(playerG.players).map(([id, player]) => {
      if (id === playerID) {
        // Show everything to the current player
        return [id, player];
      } else {
        // Hide other players' private information
        return [
          id,
          {
            ...player,
            role: shouldRevealRole(ctx.phase, id, playerID, playerG) ? player.role : '',
            originalRole: ctx.phase === GAME_PHASES.reveal ? player.originalRole : '',
            privateLog: [], // Never show other players' private logs
          }
        ];
      }
    })
  );

  // Handle center cards visibility
  let visibleCenter = playerG.center;
  if (ctx.phase !== GAME_PHASES.reveal) {
    // During the game, only show center cards that this player has seen
    const seenCards = playerG.seenCenterCards?.[playerID] || [];
    visibleCenter = playerG.center.map((role, index) => 
      seenCards.includes(index) ? role : ''
    );
  }

  return {
    ...playerG,
    players: filteredPlayers,
    center: visibleCenter,
    // Filter night actions to only show this player's actions during night phase
    nightActions: ctx.phase === GAME_PHASES.reveal 
      ? playerG.nightActions 
      : playerG.nightActions.filter(action => action.actor === playerID),
  };
}

function shouldRevealRole(
  phase: string, 
  targetPlayerID: PlayerID, 
  viewerPlayerID: PlayerID, 
  G: GameState
): boolean {
  // Always reveal during reveal phase
  if (phase === GAME_PHASES.reveal) {
    return true;
  }

  // Don't reveal roles during other phases unless specifically seen
  // This could be extended to handle roles like Seer that see other players
  
  // Check if the viewer has seen this player's role through a night action
  const viewer = G.players[viewerPlayerID];
  if (viewer && viewer.privateLog) {
    // Look for log entries that might indicate the player saw this role
    // This is a simple implementation - could be more sophisticated
    return viewer.privateLog.some(log => 
      log.includes(targetPlayerID) && log.includes('role')
    );
  }

  return false;
}