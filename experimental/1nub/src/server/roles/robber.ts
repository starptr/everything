import { RoleDefinition } from '../../shared/types';
import { validatePlayerTarget } from '../util/gameUtils';

export const Robber: RoleDefinition = {
  id: 'robber',
  name: 'Robber',
  description: 'You may swap your card with another player\'s card, and then look at your new card.',
  nightOrder: 6,
  
  nightAction: {
    uiPrompt: {
      type: "choosePlayer",
      min: 0,
      max: 1,
      label: "Choose a player to rob (swap roles with), or choose no one to do nothing",
    },
    
    validator: (G, ctx, payload) => {
      const { target } = payload;
      
      if (!target) {
        // Robber can choose not to act
        return true;
      }
      
      const playerIds = Object.keys(G.players);
      return validatePlayerTarget(ctx.currentPlayer || '', target, playerIds);
    },
    
    perform: (G, ctx, { actor, target }) => {
      const actorPlayer = G.players[actor];
      
      if (!target) {
        // Robber chose not to act
        actorPlayer.privateLog.push("You chose not to rob anyone.");
        return;
      }
      
      const targetPlayer = G.players[target];
      if (!targetPlayer) {
        return;
      }
      
      // Swap roles
      const actorOldRole = actorPlayer.role;
      const targetOldRole = targetPlayer.role;
      
      actorPlayer.role = targetOldRole;
      targetPlayer.role = actorOldRole;
      
      // Robber learns their new role
      actorPlayer.privateLog.push(
        `You robbed Player ${targetPlayer.seat + 1}. Your new role is: ${actorPlayer.role}`
      );
      
      // Target doesn't learn about the swap until the end
    }
  }
};