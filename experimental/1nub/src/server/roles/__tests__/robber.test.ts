import { Robber } from '../robber';
import { GameState } from '../../../shared/types';

describe('Robber Role', () => {
  let mockGameState: GameState;
  let mockCtx: any;

  beforeEach(() => {
    mockGameState = {
      players: {
        '0': {
          id: '0',
          seat: 0,
          role: 'robber',
          originalRole: 'robber',
          privateLog: [],
          connected: true,
          hasActed: false,
        },
        '1': {
          id: '1',
          seat: 1,
          role: 'werewolf',
          originalRole: 'werewolf',
          privateLog: [],
          connected: true,
          hasActed: false,
        },
      },
      center: ['seer', 'troublemaker', 'villager'],
      votes: {},
      nightActions: [],
      revealed: null,
      nightStep: 0,
      currentNightRole: null,
      gameOptions: {
        enabledRoles: ['robber', 'werewolf', 'seer', 'troublemaker', 'villager'],
      },
      seenCenterCards: {},
    };

    mockCtx = {
      currentPlayer: '0',
      phase: 'night',
    };
  });

  it('should have correct basic properties', () => {
    expect(Robber.id).toBe('robber');
    expect(Robber.name).toBe('Robber');
    expect(Robber.nightOrder).toBe(6);
    expect(Robber.nightAction).toBeDefined();
  });

  it('should allow robber to swap roles with another player', () => {
    const initialRobberRole = mockGameState.players['0'].role;
    const initialTargetRole = mockGameState.players['1'].role;
    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Robber.nightAction!.perform(mockGameState, mockCtx, { 
      actor: '0', 
      target: '1' 
    });

    // Roles should be swapped
    expect(mockGameState.players['0'].role).toBe(initialTargetRole);
    expect(mockGameState.players['1'].role).toBe(initialRobberRole);

    // Robber should learn their new role
    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('Player 2');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('werewolf');
  });

  it('should allow robber to choose not to act', () => {
    const initialRobberRole = mockGameState.players['0'].role;
    const initialTargetRole = mockGameState.players['1'].role;
    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Robber.nightAction!.perform(mockGameState, mockCtx, { 
      actor: '0'
      // No target specified
    });

    // Roles should remain unchanged
    expect(mockGameState.players['0'].role).toBe(initialRobberRole);
    expect(mockGameState.players['1'].role).toBe(initialTargetRole);

    // Log should indicate no action taken
    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('chose not to rob');
  });

  it('should validate target selection correctly', () => {
    const validator = Robber.nightAction!.validator!;

    // Valid player target
    expect(validator(mockGameState, mockCtx, { target: '1' })).toBe(true);

    // Valid: no target (passing)
    expect(validator(mockGameState, mockCtx, {})).toBe(true);

    // Invalid: target self
    expect(validator(mockGameState, mockCtx, { target: '0' })).toBe(false);

    // Invalid: target non-existent player
    expect(validator(mockGameState, mockCtx, { target: '99' })).toBe(false);
  });

  it('should have appropriate UI prompt', () => {
    expect(Robber.nightAction!.uiPrompt).toBeDefined();
    expect(Robber.nightAction!.uiPrompt!.type).toBe('choosePlayer');
    expect(Robber.nightAction!.uiPrompt!.min).toBe(0);
    expect(Robber.nightAction!.uiPrompt!.max).toBe(1);
  });
});