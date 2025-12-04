import { RoleDefinition, RoleId } from '../../shared/types';
import { Werewolf } from './werewolf';
import { Seer } from './seer';
import { Robber } from './robber';
import { Villager } from './villager';
import { Troublemaker } from './troublemaker';

export const ROLE_REGISTRY: Record<RoleId, RoleDefinition> = {
  werewolf: Werewolf,
  seer: Seer,
  robber: Robber,
  villager: Villager,
  troublemaker: Troublemaker,
};

export function getRoleDefinition(roleId: RoleId): RoleDefinition | undefined {
  return ROLE_REGISTRY[roleId];
}

export function getAllRoles(): RoleDefinition[] {
  return Object.values(ROLE_REGISTRY);
}

export function getRolesByNightOrder(): RoleDefinition[] {
  return getAllRoles().sort((a, b) => a.nightOrder - b.nightOrder);
}