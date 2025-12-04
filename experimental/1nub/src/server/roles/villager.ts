import { RoleDefinition } from '../../shared/types';

export const Villager: RoleDefinition = {
  id: 'villager',
  name: 'Villager',
  description: 'You have no special abilities. Try to find the werewolves during the day phase.',
  nightOrder: 10,
  
  // Villagers have no night action
};