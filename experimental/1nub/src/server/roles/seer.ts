import { RoleDefinition } from '../../shared/types';
import { validatePlayerTarget, validateCenterTarget } from '../util/gameUtils';

export const Seer: RoleDefinition = {
  id: 'seer',
  name: 'Seer',
  description: 'You may look at another player\'s card, or you may look at two of the center cards.',
  nightOrder: 5,
  
  nightAction: {
    uiPrompt: {
      type: "choosePlayer",
      min: 0,
      max: 1,
      label: "Choose a player to look at their card, or choose no one to look at two center cards",
      extraFields: {
        allowCenterCards: true,
        centerCardCount: 2
      }
    },
    
    validator: (G, ctx, payload) => {
      const { target, centerCard } = payload;
      
      // Must choose either a player OR center cards, not both
      if (target && centerCard !== undefined) {
        return false;
      }
      
      if (target) {
        // If targeting a player, validate the target
        const playerIds = Object.keys(G.players);
        return validatePlayerTarget(ctx.currentPlayer || '', target, playerIds);
      } else if (centerCard !== undefined) {
        // If looking at center cards, validate the index
        return validateCenterTarget(centerCard);
      } else {
        // If no target specified, default to center cards
        return true;
      }
    },
    
    perform: (G, ctx, { actor, target, centerCard }) => {
      const actorPlayer = G.players[actor];
      
      if (target) {
        // Look at another player's card
        const targetPlayer = G.players[target];
        if (targetPlayer) {
          actorPlayer.privateLog.push(
            `You looked at Player ${targetPlayer.seat + 1}'s card: ${targetPlayer.role}`
          );
        }
      } else {
        // Look at two center cards (default action)
        const centerCards = G.center.slice(0, 2);
        actorPlayer.privateLog.push(
          `You looked at two center cards: ${centerCards[0]} and ${centerCards[1]}`
        );
        
        // Track that this player has seen these center cards
        if (!G.seenCenterCards) {
          G.seenCenterCards = {};
        }
        if (!G.seenCenterCards[actor]) {
          G.seenCenterCards[actor] = [];
        }
        G.seenCenterCards[actor].push(0, 1);
      }
    }
  }
};