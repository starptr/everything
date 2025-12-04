import { Game, Ctx } from 'boardgame.io';
import { INVALID_MOVE } from 'boardgame.io/core';
import { 
  GameState, 
  PlayerState, 
  PlayerID, 
  RoleId, 
  GAME_PHASES, 
  StartGamePayload, 
  SeatPlayerPayload,
  ExecuteNightActionPayload,
  CastVotePayload
} from '../shared/types';
import { ROLE_REGISTRY } from './roles';
import { shuffleArray, dealRoles } from './util/gameUtils';
import { createPlayerView } from './util/playerView';

const MIN_PLAYERS = 3;
const MAX_PLAYERS = 10;
const CENTER_CARDS = 3;

function setup(ctx: Ctx): GameState {
  return {
    players: {},
    center: [],
    votes: {},
    nightActions: [],
    revealed: null,
    nightStep: 0,
    currentNightRole: null,
    gameOptions: {
      enabledRoles: [],
      timeLimit: 300, // 5 minutes default
      autoAdvance: false
    },
    seenCenterCards: {}
  };
}

// Move: Players can take a seat in the lobby
function seatPlayer(G: GameState, ctx: Ctx, { seat }: SeatPlayerPayload) {
  if (ctx.phase !== GAME_PHASES.lobby) {
    return INVALID_MOVE;
  }

  const playerID = ctx.currentPlayer;
  
  // Check if seat is already taken
  const seatTaken = Object.values(G.players).some(player => player.seat === seat);
  if (seatTaken) {
    return INVALID_MOVE;
  }

  // Check valid seat range
  if (seat < 0 || seat >= MAX_PLAYERS) {
    return INVALID_MOVE;
  }

  // If player is already seated, remove from old seat
  if (G.players[playerID]) {
    delete G.players[playerID];
  }

  // Add player to new seat
  G.players[playerID] = {
    id: playerID,
    seat,
    role: '',
    originalRole: '',
    privateLog: [],
    connected: true,
    hasActed: false
  };
}

// Move: Leave current seat
function leaveSeat(G: GameState, ctx: Ctx) {
  if (ctx.phase !== GAME_PHASES.lobby) {
    return INVALID_MOVE;
  }

  const playerID = ctx.currentPlayer;
  if (G.players[playerID]) {
    delete G.players[playerID];
  }
}

// Move: Start the game (host only)
function startGame(G: GameState, ctx: Ctx, { options = {} }: StartGamePayload) {
  if (ctx.phase !== GAME_PHASES.lobby) {
    return INVALID_MOVE;
  }

  const playerCount = Object.keys(G.players).length;
  if (playerCount < MIN_PLAYERS || playerCount > MAX_PLAYERS) {
    return INVALID_MOVE;
  }

  // Apply game options
  G.gameOptions = { ...G.gameOptions, ...options };

  // Use default role set if none specified
  if (!options.enabledRoles || options.enabledRoles.length === 0) {
    const defaultRoles = ['werewolf', 'werewolf', 'seer', 'robber', 'troublemaker', 'villager', 'villager'];
    G.gameOptions.enabledRoles = defaultRoles.slice(0, playerCount + CENTER_CARDS);
  }

  // Deal roles to players and center
  const { playerRoles, centerRoles } = dealRoles(G.gameOptions.enabledRoles, playerCount);
  
  // Assign roles to players
  const playerIDs = Object.keys(G.players);
  playerIDs.forEach((playerID, index) => {
    const player = G.players[playerID];
    player.role = playerRoles[index];
    player.originalRole = playerRoles[index];
    player.hasActed = false;
    player.privateLog = [`You are the ${ROLE_REGISTRY[player.role]?.name || player.role}.`];
  });

  // Set center cards
  G.center = centerRoles;

  // Reset night state
  G.nightStep = 0;
  G.currentNightRole = null;
  G.nightActions = [];
  G.votes = {};

  // Move to night phase
  ctx.events?.setPhase?.(GAME_PHASES.night);
}

// Move: Execute a night action for current player's role
function executeNightAction(G: GameState, ctx: Ctx, payload: ExecuteNightActionPayload) {
  if (ctx.phase !== GAME_PHASES.night) {
    return INVALID_MOVE;
  }

  const playerID = ctx.currentPlayer;
  const player = G.players[playerID];
  
  if (!player || player.hasActed) {
    return INVALID_MOVE;
  }

  const roleDefinition = ROLE_REGISTRY[player.role];
  if (!roleDefinition || !roleDefinition.nightAction) {
    return INVALID_MOVE;
  }

  try {
    // Validate the action if validator exists
    if (roleDefinition.nightAction.validator && 
        !roleDefinition.nightAction.validator(G, ctx, payload)) {
      return INVALID_MOVE;
    }

    // Execute the action
    roleDefinition.nightAction.perform(G, ctx, { actor: playerID, ...payload });

    // Mark player as having acted
    player.hasActed = true;

    // Record the action
    G.nightActions.push({
      actor: playerID,
      roleId: player.role,
      payload,
      timestamp: Date.now()
    });

  } catch (error) {
    return INVALID_MOVE;
  }
}

// Move: Pass on night action (for roles that can choose not to act)
function passNightAction(G: GameState, ctx: Ctx) {
  if (ctx.phase !== GAME_PHASES.night) {
    return INVALID_MOVE;
  }

  const playerID = ctx.currentPlayer;
  const player = G.players[playerID];
  
  if (!player || player.hasActed) {
    return INVALID_MOVE;
  }

  // Mark player as having acted (by passing)
  player.hasActed = true;
  player.privateLog.push("You chose not to use your night action.");
}

// Move: Cast a vote during voting phase
function castVote(G: GameState, ctx: Ctx, { target }: CastVotePayload) {
  if (ctx.phase !== GAME_PHASES.voting) {
    return INVALID_MOVE;
  }

  const voterID = ctx.currentPlayer;
  const voter = G.players[voterID];
  const targetPlayer = G.players[target];

  if (!voter || !targetPlayer) {
    return INVALID_MOVE;
  }

  G.votes[voterID] = target;
}

// Move: Advance to day phase (when night is complete)
function startDay(G: GameState, ctx: Ctx) {
  if (ctx.phase !== GAME_PHASES.night) {
    return INVALID_MOVE;
  }

  // Check if all players with night actions have acted
  const playersWithActions = Object.values(G.players).filter(player => {
    const roleDefinition = ROLE_REGISTRY[player.role];
    return roleDefinition && roleDefinition.nightAction;
  });

  const allActed = playersWithActions.every(player => player.hasActed);
  if (!allActed) {
    return INVALID_MOVE;
  }

  ctx.events?.setPhase?.(GAME_PHASES.day);
}

// Move: Advance to voting phase
function startVoting(G: GameState, ctx: Ctx) {
  if (ctx.phase !== GAME_PHASES.day) {
    return INVALID_MOVE;
  }

  ctx.events?.setPhase?.(GAME_PHASES.voting);
}

// Move: Finalize votes and determine winners
function finalizeVotes(G: GameState, ctx: Ctx) {
  if (ctx.phase !== GAME_PHASES.voting) {
    return INVALID_MOVE;
  }

  // Count votes
  const voteCounts: Record<PlayerID, number> = {};
  Object.values(G.votes).forEach(target => {
    voteCounts[target] = (voteCounts[target] || 0) + 1;
  });

  // Find players with most votes (eliminated players)
  const maxVotes = Math.max(...Object.values(voteCounts), 0);
  const eliminatedPlayers = Object.keys(voteCounts).filter(
    playerID => voteCounts[playerID] === maxVotes
  );

  // Determine winners based on game rules
  const winners = determineWinners(G, eliminatedPlayers);
  
  G.revealed = {
    winners,
    endSummary: {
      finalRoles: Object.fromEntries(
        Object.entries(G.players).map(([id, player]) => [id, player.role])
      ),
      originalRoles: Object.fromEntries(
        Object.entries(G.players).map(([id, player]) => [id, player.originalRole])
      ),
      votes: { ...G.votes },
      eliminatedPlayers,
      winCondition: getWinCondition(G, eliminatedPlayers, winners)
    }
  };

  ctx.events?.setPhase?.(GAME_PHASES.reveal);
}

function determineWinners(G: GameState, eliminatedPlayers: PlayerID[]): PlayerID[] {
  const werewolves = Object.entries(G.players)
    .filter(([_, player]) => player.role === 'werewolf')
    .map(([id, _]) => id);

  const werewolvesEliminated = eliminatedPlayers.some(id => werewolves.includes(id));

  if (werewolves.length === 0) {
    // No werewolves in play - villagers need to eliminate no one or a villager
    if (eliminatedPlayers.length === 0) {
      return Object.keys(G.players).filter(id => !werewolves.includes(id));
    } else {
      // Check if eliminated player was originally a villager
      const eliminatedWasVillager = eliminatedPlayers.some(id => 
        ['villager', 'seer', 'robber', 'troublemaker'].includes(G.players[id].originalRole)
      );
      return eliminatedWasVillager ? Object.keys(G.players).filter(id => !werewolves.includes(id)) : [];
    }
  } else {
    // Werewolves present - villagers win if werewolf eliminated, werewolves win if not
    return werewolvesEliminated 
      ? Object.keys(G.players).filter(id => !werewolves.includes(id))
      : werewolves;
  }
}

function getWinCondition(G: GameState, eliminatedPlayers: PlayerID[], winners: PlayerID[]): string {
  const werewolves = Object.entries(G.players)
    .filter(([_, player]) => player.role === 'werewolf')
    .map(([id, _]) => id);

  if (werewolves.length === 0) {
    return eliminatedPlayers.length === 0 ? "No werewolves - villagers win by not eliminating anyone" 
                                          : "No werewolves - villagers win by eliminating a villager";
  } else {
    const werewolfEliminated = eliminatedPlayers.some(id => werewolves.includes(id));
    return werewolfEliminated ? "Werewolf eliminated - villagers win" 
                              : "Werewolf survives - werewolves win";
  }
}

export const OneNightWerewolf: Game<GameState> = {
  name: 'OneNightWerewolf',
  setup,
  playerView: createPlayerView,
  
  phases: {
    [GAME_PHASES.lobby]: {
      moves: { seatPlayer, leaveSeat, startGame },
      start: true,
    },
    [GAME_PHASES.night]: {
      moves: { executeNightAction, passNightAction, startDay },
    },
    [GAME_PHASES.day]: {
      moves: { startVoting },
    },
    [GAME_PHASES.voting]: {
      moves: { castVote, finalizeVotes },
    },
    [GAME_PHASES.reveal]: {
      moves: {},
    },
  },

  minPlayers: MIN_PLAYERS,
  maxPlayers: MAX_PLAYERS,
};