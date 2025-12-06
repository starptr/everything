import { Game } from 'boardgame.io';
import { PlayerView } from 'boardgame.io/core';
import { GState, DEFAULT_ROLES } from './types';

const OneNightWerewolf: Game<GState> = {
  name: 'OneNightWerewolf',
  
  setup: () => ({
    players: {},
    secret: {
      center: [],
      nightActions: [],
      currentNightStep: 0,
    },
    votes: {},
    nightOrder: [],
    gameOptions: {
      enabledRoles: DEFAULT_ROLES,
      nightTimeLimit: 300000,
      dayTimeLimit: 300000, 
      votingTimeLimit: 60000
    },
    revealed: null,
    timers: {}
  }),


  phases: {
    lobby: {
      start: true,
      moves: {
        seatPlayer: ({ G, playerID }, seat: number, playerName: string): void => {
          if (G.players[playerID]) return;
          
          const existingPlayer = Object.values(G.players).find((p: any) => p.seat === seat);
          if (existingPlayer) return;

          G.players[playerID] = {
            id: playerID,
            name: playerName,
            seat,
            role: "",
            originalRole: "",
            privateLog: [],
            connected: true
          };
        },
        startGame: ({ G }: any) => {
          const playerIds = Object.keys(G.players);
          const numPlayers = playerIds.length;
          
          if (numPlayers < 3 || numPlayers > 10) return;

          const roles = [...DEFAULT_ROLES].sort(() => Math.random() - 0.5);
          
          playerIds.forEach((playerId, index) => {
            G.players[playerId].role = roles[index];
            G.players[playerId].originalRole = roles[index];
          });
          
          G.center = roles.slice(numPlayers, numPlayers + 3);
          G.currentNightStep = 0;
          G.nightOrder = ["werewolf", "seer", "robber", "troublemaker"];
        }
      },
      next: 'night'
    },
    night: {
      moves: {
        executeNightAction: ({ G, playerID }: any, payload: any) => {
          const currentRole = G.nightOrder[G.currentNightStep];
          const player = G.players[playerID];
          
          if (!player || player.originalRole !== currentRole) return;
          
          if (currentRole === 'seer' && payload.target) {
            const target = G.players[payload.target];
            player.privateLog.push(`You saw ${target.name}'s role: ${target.role}`);
          } else if (currentRole === 'robber' && payload.target) {
            const target = G.players[payload.target];
            const temp = player.role;
            player.role = target.role;
            target.role = temp;
            player.privateLog.push(`You swapped with ${target.name}. Your new role: ${player.role}`);
          }
          
          const actedPlayers = G.nightActions.filter((a: any) => a.roleId === currentRole).length;
          const totalPlayers = Object.values(G.players).filter((p: any) => p.originalRole === currentRole).length;
          
          G.nightActions.push({ actor: playerID, roleId: currentRole, payload });
          
          if (actedPlayers + 1 >= totalPlayers) {
            G.currentNightStep++;
          }
        }
      },
      next: 'day',
      endIf: ({ G }: any) => G.currentNightStep >= G.nightOrder.length
    },
    day: {
      moves: {
        startVoting: () => {}
      },
      next: 'voting'
    },
    voting: {
      moves: {
        castVote: ({ G, playerID }: any, target: string) => {
          if (!G.players[target]) return;
          G.votes[playerID] = target;
        }
      },
      next: 'reveal',
      endIf: ({ G }: any) => {
        const numPlayers = Object.keys(G.players).length;
        const numVotes = Object.keys(G.votes).length;
        return numVotes === numPlayers;
      }
    },
    reveal: {
      moves: {
        resetGame: ({ G }: any) => {
          Object.values(G.players).forEach((player: any) => {
            player.role = "";
            player.originalRole = "";
            player.privateLog = [];
          });
          G.center = [];
          G.votes = {};
          G.nightActions = [];
          G.currentNightStep = 0;
          G.nightOrder = [];
          G.revealed = null;
        }
      },
      onBegin: ({ G }: any) => {
        // Calculate winners
        const votes: Record<string, number> = {};
        Object.values(G.players).forEach((player: any) => {
          votes[player.id] = 0;
        });
        
        Object.values(G.votes).forEach((target: any) => {
          votes[target]++;
        });

        const maxVotes = Math.max(...Object.values(votes));
        const eliminated = Object.keys(votes).filter(id => votes[id] === maxVotes);
        
        const eliminatedWerewolves = eliminated.filter(id => G.players[id].role === 'werewolf');
        
        G.revealed = {
          winners: eliminatedWerewolves.length > 0 ? 
            Object.keys(G.players).filter(id => G.players[id].role !== 'werewolf') :
            Object.keys(G.players).filter(id => G.players[id].role === 'werewolf'),
          endSummary: {
            finalRoles: Object.fromEntries(Object.values(G.players).map((p: any) => [p.id, p.role])),
            voteTally: votes,
            eliminatedPlayers: eliminated,
            winCondition: eliminatedWerewolves.length > 0 ? 
              'Village wins!' : 'Werewolves win!'
          }
        };
      }
    }
  },

  // Use the built-in player view to strip secret information.
  // This will strip the `secret` property and any entry in `players` that is not the current player.
  playerView: PlayerView.STRIP_SECRETS,
};

export default OneNightWerewolf;