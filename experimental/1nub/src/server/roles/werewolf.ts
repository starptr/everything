import { RoleDefinition } from '../../shared/types';

export const Werewolf: RoleDefinition = {
  id: 'werewolf',
  name: 'Werewolf',
  description: 'You wake up and look for other werewolves. If you are the only werewolf, you may look at one center card.',
  nightOrder: 2,
  
  nightAction: {
    uiPrompt: {
      type: "noPrompt",
      label: "Looking for other werewolves..."
    },
    
    perform: (G, ctx, { actor }) => {
      const actorPlayer = G.players[actor];
      const otherWerewolves = Object.entries(G.players)
        .filter(([id, player]) => id !== actor && player.role === 'werewolf')
        .map(([id, _]) => id);

      if (otherWerewolves.length > 0) {
        // Multiple werewolves - they see each other
        const werewolfNames = otherWerewolves
          .map(id => `Player ${G.players[id].seat + 1}`)
          .join(', ');
        actorPlayer.privateLog.push(`You see the other werewolf(es): ${werewolfNames}`);
      } else {
        // Lone werewolf - gets to see a center card
        // For now, automatically show them the first center card
        // In a full implementation, this would be a choice
        const centerCard = G.center[0];
        actorPlayer.privateLog.push(`You are the lone werewolf. The first center card is: ${centerCard}`);
        
        // Track that this player has seen this center card
        if (!G.seenCenterCards) {
          G.seenCenterCards = {};
        }
        if (!G.seenCenterCards[actor]) {
          G.seenCenterCards[actor] = [];
        }
        G.seenCenterCards[actor].push(0);
      }
    }
  }
};