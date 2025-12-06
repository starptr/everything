import { RoleDefinition, RoleId } from "../types";
import Werewolf from "./werewolf";
import Seer from "./seer";
import Robber from "./robber";
import Troublemaker from "./troublemaker";
import Villager from "./villager";

export const ROLE_REGISTRY: Record<RoleId, RoleDefinition> = {
  werewolf: Werewolf,
  seer: Seer,
  robber: Robber,
  troublemaker: Troublemaker,
  villager: Villager
};

export function getRoleDefinition(roleId: RoleId): RoleDefinition {
  const role = ROLE_REGISTRY[roleId];
  if (!role) {
    throw new Error(`Unknown role: ${roleId}`);
  }
  return role;
}

export function getAllRoles(): RoleDefinition[] {
  return Object.values(ROLE_REGISTRY);
}

export function getRolesByTeam(team: "werewolf" | "village" | "special"): RoleDefinition[] {
  return Object.values(ROLE_REGISTRY).filter(role => role.team === team);
}

export default ROLE_REGISTRY;