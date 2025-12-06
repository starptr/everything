import OneNightWerewolf from '../src/server/game-simple';
import { DEFAULT_ROLES } from '../src/server/types';

describe('OneNightWerewolf Game', () => {
  test('should initialize with correct setup', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    expect(state.players).toEqual({});
    expect(state.center).toEqual([]);
    expect(state.votes).toEqual({});
    expect(state.nightActions).toEqual([]);
    expect(state.currentNightStep).toBe(0);
    expect(state.gameOptions.enabledRoles).toEqual(DEFAULT_ROLES);
    expect(state.revealed).toBeNull();
  });

  test('should handle player seating', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    const mockContext = {
      G: state,
      playerID: 'player1'
    };

    // Test seating a player
    const seatPlayerMove = game.phases!.lobby.moves!.seatPlayer;
    if (typeof seatPlayerMove === 'function') {
      seatPlayerMove(mockContext, 1, 'Alice');
    }

    expect(state.players['player1']).toBeDefined();
    expect(state.players['player1'].name).toBe('Alice');
    expect(state.players['player1'].seat).toBe(1);
    expect(state.players['player1'].role).toBe('');
    expect(state.players['player1'].originalRole).toBe('');
  });

  test('should prevent duplicate seat assignment', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    // Seat first player
    const mockContext1 = { G: state, playerID: 'player1' };
    const seatPlayerMove = game.phases!.lobby.moves!.seatPlayer;
    if (typeof seatPlayerMove === 'function') {
      seatPlayerMove(mockContext1, 1, 'Alice');
      
      // Try to seat second player in same seat
      const mockContext2 = { G: state, playerID: 'player2' };
      seatPlayerMove(mockContext2, 1, 'Bob');
    }

    expect(Object.keys(state.players)).toHaveLength(1);
    expect(state.players['player1'].name).toBe('Alice');
    expect(state.players['player2']).toBeUndefined();
  });

  test('should start game and deal roles', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    // Add some players
    state.players['player1'] = { id: 'player1', name: 'Alice', seat: 1, role: '', originalRole: '', privateLog: [], connected: true };
    state.players['player2'] = { id: 'player2', name: 'Bob', seat: 2, role: '', originalRole: '', privateLog: [], connected: true };
    state.players['player3'] = { id: 'player3', name: 'Charlie', seat: 3, role: '', originalRole: '', privateLog: [], connected: true };

    const mockContext = { G: state, playerID: 'player1' };
    const startGameMove = game.phases!.lobby.moves!.startGame;
    
    if (typeof startGameMove === 'function') {
      startGameMove(mockContext);
    }

    // Check that roles were assigned
    expect(state.players['player1'].role).toBeTruthy();
    expect(state.players['player2'].role).toBeTruthy();
    expect(state.players['player3'].role).toBeTruthy();
    
    expect(state.players['player1'].originalRole).toBeTruthy();
    expect(state.players['player2'].originalRole).toBeTruthy();
    expect(state.players['player3'].originalRole).toBeTruthy();

    // Check center cards
    expect(state.center).toHaveLength(3);
    expect(state.center.every(role => typeof role === 'string')).toBe(true);

    // Check night setup
    expect(state.currentNightStep).toBe(0);
    expect(state.nightOrder).toHaveLength(4);
  });

  test('should handle voting', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    // Setup players
    state.players['player1'] = { id: 'player1', name: 'Alice', seat: 1, role: 'villager', originalRole: 'villager', privateLog: [], connected: true };
    state.players['player2'] = { id: 'player2', name: 'Bob', seat: 2, role: 'werewolf', originalRole: 'werewolf', privateLog: [], connected: true };

    const mockContext = { G: state, playerID: 'player1' };
    const castVoteMove = game.phases!.voting.moves!.castVote;
    
    if (typeof castVoteMove === 'function') {
      castVoteMove(mockContext, 'player2');
    }

    expect(state.votes['player1']).toBe('player2');
  });

  test('should calculate winners correctly', () => {
    const game = OneNightWerewolf;
    const state = game.setup!();
    
    // Setup test scenario
    state.players['player1'] = { id: 'player1', name: 'Alice', seat: 1, role: 'villager', originalRole: 'villager', privateLog: [], connected: true };
    state.players['player2'] = { id: 'player2', name: 'Bob', seat: 2, role: 'werewolf', originalRole: 'werewolf', privateLog: [], connected: true };
    state.players['player3'] = { id: 'player3', name: 'Charlie', seat: 3, role: 'seer', originalRole: 'seer', privateLog: [], connected: true };

    // Setup votes - everyone votes for the werewolf
    state.votes = {
      'player1': 'player2',
      'player2': 'player1', // werewolf tries to deflect
      'player3': 'player2'
    };

    const mockContext = { G: state };
    const revealOnBegin = game.phases!.reveal.onBegin;
    
    if (typeof revealOnBegin === 'function') {
      revealOnBegin(mockContext);
    }

    expect(state.revealed).not.toBeNull();
    expect(state.revealed!.winners).toEqual(['player1', 'player3']); // Village team wins
    expect(state.revealed!.endSummary.winCondition).toBe('Village wins!');
    expect(state.revealed!.endSummary.eliminatedPlayers).toEqual(['player2']);
  });
});