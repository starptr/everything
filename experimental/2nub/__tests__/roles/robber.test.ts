import Robber from '../../src/server/roles/robber';
import { GState } from '../../src/server/types';

describe('Robber Role', () => {
  test('should have correct role definition', () => {
    expect(Robber.id).toBe('robber');
    expect(Robber.name).toBe('Robber');
    expect(Robber.team).toBe('village');
    expect(Robber.nightAction).toBeDefined();
  });

  test('should swap roles when targeting another player', () => {
    const G: GState = {
      players: {
        'player1': { id: 'player1', name: 'Alice', seat: 1, role: 'robber', originalRole: 'robber', privateLog: [], connected: true },
        'player2': { id: 'player2', name: 'Bob', seat: 2, role: 'werewolf', originalRole: 'werewolf', privateLog: [], connected: true }
      },
      center: ['villager', 'seer', 'troublemaker'],
      votes: {},
      nightActions: [],
      currentNightStep: 0,
      nightOrder: [],
      gameOptions: { enabledRoles: [] },
      revealed: null,
      timers: {}
    };

    const ctx: any = { currentPlayer: 'player1' };
    
    if (Robber.nightAction?.perform) {
      Robber.nightAction.perform(G, ctx, { actor: 'player1', target: 'player2' });
    }

    expect(G.players['player1'].role).toBe('werewolf');
    expect(G.players['player2'].role).toBe('robber');
    expect(G.players['player1'].privateLog).toContain('You swapped roles with Bob. Your new role: werewolf');
  });

  test('should allow skipping the action', () => {
    const G: GState = {
      players: {
        'player1': { id: 'player1', name: 'Alice', seat: 1, role: 'robber', originalRole: 'robber', privateLog: [], connected: true },
        'player2': { id: 'player2', name: 'Bob', seat: 2, role: 'werewolf', originalRole: 'werewolf', privateLog: [], connected: true }
      },
      center: ['villager', 'seer', 'troublemaker'],
      votes: {},
      nightActions: [],
      currentNightStep: 0,
      nightOrder: [],
      gameOptions: { enabledRoles: [] },
      revealed: null,
      timers: {}
    };

    const ctx: any = { currentPlayer: 'player1' };
    
    if (Robber.nightAction?.perform) {
      Robber.nightAction.perform(G, ctx, { actor: 'player1' }); // No target
    }

    // Roles should remain unchanged
    expect(G.players['player1'].role).toBe('robber');
    expect(G.players['player2'].role).toBe('werewolf');
    expect(G.players['player1'].privateLog).toContain('You chose not to rob anyone.');
  });

  test('validator should prevent self-targeting', () => {
    const G: any = {};
    const ctx: any = { currentPlayer: 'player1' };
    const payload = { target: 'player1' }; // Self-targeting

    if (Robber.nightAction?.validator) {
      const isValid = Robber.nightAction.validator(G, ctx, payload);
      expect(isValid).toBe(false);
    }
  });

  test('validator should allow valid targets', () => {
    const G: any = {};
    const ctx: any = { currentPlayer: 'player1' };
    const payload = { target: 'player2' }; // Different player

    if (Robber.nightAction?.validator) {
      const isValid = Robber.nightAction.validator(G, ctx, payload);
      expect(isValid).toBe(true);
    }
  });
});