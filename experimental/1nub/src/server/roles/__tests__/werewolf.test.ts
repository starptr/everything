import { Werewolf } from '../werewolf';
import { GameState, PlayerState } from '../../../shared/types';

describe('Werewolf Role', () => {
  let mockGameState: GameState;
  let mockCtx: any;

  beforeEach(() => {
    mockGameState = {
      players: {
        '0': {
          id: '0',
          seat: 0,
          role: 'werewolf',
          originalRole: 'werewolf',
          privateLog: [],
          connected: true,
          hasActed: false,
        },
        '1': {
          id: '1',
          seat: 1,
          role: 'villager',
          originalRole: 'villager',
          privateLog: [],
          connected: true,
          hasActed: false,
        },
      },
      center: ['seer', 'robber', 'troublemaker'],
      votes: {},
      nightActions: [],
      revealed: null,
      nightStep: 0,
      currentNightRole: null,
      gameOptions: {
        enabledRoles: ['werewolf', 'villager', 'seer', 'robber', 'troublemaker'],
      },
      seenCenterCards: {},
    };

    mockCtx = {
      currentPlayer: '0',
      phase: 'night',
    };
  });

  it('should have correct basic properties', () => {
    expect(Werewolf.id).toBe('werewolf');
    expect(Werewolf.name).toBe('Werewolf');
    expect(Werewolf.nightOrder).toBe(2);
    expect(Werewolf.nightAction).toBeDefined();
  });

  it('should allow lone werewolf to see a center card', () => {
    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Werewolf.nightAction!.perform(mockGameState, mockCtx, { actor: '0' });

    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('lone werewolf');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('center card');
    expect(mockGameState.seenCenterCards!['0']).toContain(0);
  });

  it('should allow multiple werewolves to see each other', () => {
    // Add another werewolf
    mockGameState.players['1'].role = 'werewolf';
    mockGameState.players['1'].originalRole = 'werewolf';

    const initialLogLength = mockGameState.players['0'].privateLog.length;

    Werewolf.nightAction!.perform(mockGameState, mockCtx, { actor: '0' });

    const player = mockGameState.players['0'];
    expect(player.privateLog.length).toBe(initialLogLength + 1);
    expect(player.privateLog[player.privateLog.length - 1]).toContain('other werewolf');
    expect(player.privateLog[player.privateLog.length - 1]).toContain('Player 2'); // Seat 1 + 1
  });

  it('should have appropriate UI prompt', () => {
    expect(Werewolf.nightAction!.uiPrompt).toBeDefined();
    expect(Werewolf.nightAction!.uiPrompt!.type).toBe('noPrompt');
  });
});