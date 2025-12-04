import { Seer } from '../seer';
import { GameState } from '../../../shared/types';

describe('Seer Role', () => {
  let mockGameState: GameState;
  let mockCtx: any;

  beforeEach(() => {
    mockGameState = {
      players: {
        '0': {
          id: '0',
          seat: 0,
          role: 'seer',
          originalRole: 'seer',
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
      center: ['robber', 'troublemaker', 'villager'],
      votes: {},
      nightActions: [],
      revealed: null,
      nightStep: 0,
      currentNightRole: null,
      gameOptions: {
        enabledRoles: ['seer', 'werewolf', 'robber', 'troublemaker', 'villager'],
      },
      seenCenterCards: {},
    };

    mockCtx = {
      currentPlayer: '0',
      phase: 'night',
    };
  });

  it('should have correct basic properties', () => {
    expect(Seer.id).toBe('seer');
    expect(Seer.name).toBe('Seer');
    expect(Seer.nightOrder).toBe(5);
    expect(Seer.nightAction).toBeDefined();
  });

  it('should allow seer to look at another player\'s card', () => {
    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Seer.nightAction!.perform(mockGameState, mockCtx, { 
      actor: '0', 
      target: '1' 
    });

    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('Player 2');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('werewolf');
  });

  it('should allow seer to look at center cards', () => {
    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Seer.nightAction!.perform(mockGameState, mockCtx, { 
      actor: '0' 
    });

    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('center cards');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('robber');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('troublemaker');
    expect(mockGameState.seenCenterCards!['0']).toEqual([0, 1]);
  });

  it('should validate target selection correctly', () => {
    const validator = Seer.nightAction!.validator!;

    // Valid player target
    expect(validator(mockGameState, mockCtx, { target: '1' })).toBe(true);

    // Valid center card selection
    expect(validator(mockGameState, mockCtx, { centerCard: 0 })).toBe(true);

    // Invalid: both target and center card
    expect(validator(mockGameState, mockCtx, { target: '1', centerCard: 0 })).toBe(false);

    // Invalid: target self
    expect(validator(mockGameState, mockCtx, { target: '0' })).toBe(false);

    // Valid: no selection (defaults to center cards)
    expect(validator(mockGameState, mockCtx, {})).toBe(true);
  });
});