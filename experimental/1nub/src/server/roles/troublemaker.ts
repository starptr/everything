import { RoleDefinition } from '../../shared/types';
import { validatePlayerTarget } from '../util/gameUtils';

export const Troublemaker: RoleDefinition = {
  id: 'troublemaker',
  name: 'Troublemaker',
  description: 'You may swap the cards of two other players.',
  nightOrder: 7,
  
  nightAction: {
    uiPrompt: {
      type: "choosePlayers",
      min: 0,
      max: 2,
      label: "Choose two other players to swap their cards, or choose no one to do nothing",
    },
    
    validator: (G, ctx, payload) => {
      const { target } = payload;
      
      if (!target || !Array.isArray(target)) {
        // Troublemaker can choose not to act
        return true;
      }
      
      if (target.length !== 2) {
        return false;
      }
      
      const playerIds = Object.keys(G.players);
      const actor = ctx.currentPlayer || '';
      
      // Both targets must be valid and not the troublemaker
      return target.every(targetId => 
        validatePlayerTarget(actor, targetId, playerIds)
      ) && target[0] !== target[1]; // Can't swap a player with themselves
    },
    
    perform: (G, ctx, { actor, target }) => {
      const actorPlayer = G.players[actor];
      
      if (!target || !Array.isArray(target) || target.length !== 2) {
        // Troublemaker chose not to act
        actorPlayer.privateLog.push("You chose not to swap anyone's cards.");
        return;
      }
      
      const [target1Id, target2Id] = target;
      const target1Player = G.players[target1Id];
      const target2Player = G.players[target2Id];
      
      if (!target1Player || !target2Player) {
        return;
      }
      
      // Swap the roles
      const temp = target1Player.role;
      target1Player.role = target2Player.role;
      target2Player.role = temp;
      
      actorPlayer.privateLog.push(
        `You swapped the cards of Player ${target1Player.seat + 1} and Player ${target2Player.seat + 1}.`
      );
      
      // The swapped players don't learn about the swap until the end
    }
  }
};