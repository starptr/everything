import { RoleId } from '../../shared/types';

export function shuffleArray<T>(array: T[]): T[] {
  const shuffled = [...array];
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  return shuffled;
}

export function dealRoles(enabledRoles: RoleId[], playerCount: number): {
  playerRoles: RoleId[];
  centerRoles: RoleId[];
} {
  const totalCards = playerCount + 3; // 3 center cards
  
  if (enabledRoles.length < totalCards) {
    throw new Error(`Not enough roles: need ${totalCards}, have ${enabledRoles.length}`);
  }

  // Shuffle the enabled roles
  const shuffledRoles = shuffleArray(enabledRoles);
  
  return {
    playerRoles: shuffledRoles.slice(0, playerCount),
    centerRoles: shuffledRoles.slice(playerCount, playerCount + 3)
  };
}

export function getNightOrder(): RoleId[] {
  // Standard One Night Ultimate Werewolf night order
  return [
    'doppelganger', // Special - acts immediately and may gain another action
    'werewolf',     // Werewolves wake up and see each other
    'minion',       // Sees werewolves but doesn't wake them
    'mason',        // Masons see each other
    'seer',         // Sees another player's card or two center cards
    'robber',       // Swaps cards with another player and looks at new card
    'troublemaker', // Swaps two other players' cards
    'drunk',        // Swaps card with center card (doesn't look)
    'insomniac',    // Looks at own card at end of night
    'hunter',       // No night action
    'villager',     // No night action
    'tanner',       // No night action
  ];
}

export function validatePlayerTarget(
  actorId: string,
  targetId: string,
  playerIds: string[]
): boolean {
  // Can't target yourself (for most actions)
  if (actorId === targetId) {
    return false;
  }
  
  // Target must be a valid player
  return playerIds.includes(targetId);
}

export function validateCenterTarget(centerIndex: number): boolean {
  return centerIndex >= 0 && centerIndex <= 2;
}