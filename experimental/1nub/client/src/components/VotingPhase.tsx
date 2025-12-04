import React, { useState } from 'react';
import { PlayerState, PlayerID } from '../../../src/shared/types';

interface VotingPhaseProps {
  players: Record<PlayerID, PlayerState>;
  votes: Record<PlayerID, PlayerID>;
  moves: any;
  playerID?: string;
}

export const VotingPhase: React.FC<VotingPhaseProps> = ({ players, votes, moves, playerID }) => {
  const [selectedTarget, setSelectedTarget] = useState<string>('');
  const [hasVoted, setHasVoted] = useState(false);

  const currentPlayer = playerID ? players[playerID] : null;
  const myVote = playerID ? votes[playerID] : undefined;

  const handleCastVote = () => {
    if (selectedTarget && playerID) {
      moves.castVote({ target: selectedTarget });
      setHasVoted(true);
    }
  };

  const handleFinalizeVotes = () => {
    moves.finalizeVotes();
  };

  const allPlayersVoted = () => {
    const playerIds = Object.keys(players);
    return playerIds.every(id => votes[id] !== undefined);
  };

  const getVoteCount = (targetId: string): number => {
    return Object.values(votes).filter(vote => vote === targetId).length;
  };

  const playerList = Object.values(players).sort((a, b) => a.seat - b.seat);

  return (
    <div className="voting-phase">
      <div className="phase-header">
        <h2>Voting Phase</h2>
        <p>Vote for the player you think is a werewolf!</p>
      </div>

      {currentPlayer && !myVote && (
        <div className="voting-area">
          <h3>Cast Your Vote</h3>
          <p>Choose a player to vote for elimination:</p>
          
          <div className="vote-targets">
            {playerList.map(player => (
              <button
                key={player.id}
                className={`vote-btn ${selectedTarget === player.id ? 'selected' : ''} ${player.id === playerID ? 'disabled' : ''}`}
                onClick={() => {
                  if (player.id !== playerID) {
                    setSelectedTarget(selectedTarget === player.id ? '' : player.id);
                  }
                }}
                disabled={player.id === playerID}
              >
                <div className="vote-target">
                  <div className="seat">Seat {player.seat + 1}</div>
                  <div className="player-id">Player {player.id}</div>
                  {player.id === playerID && <div className="you-label">(You)</div>}
                </div>
              </button>
            ))}
          </div>

          <div className="vote-actions">
            <button 
              onClick={handleCastVote}
              disabled={!selectedTarget}
              className="cast-vote-btn"
            >
              Cast Vote
            </button>
          </div>
        </div>
      )}

      {myVote && (
        <div className="vote-confirmation">
          <h3>Your Vote</h3>
          <p>You voted for Seat {players[myVote].seat + 1} (Player {myVote})</p>
        </div>
      )}

      <div className="vote-status">
        <h3>Voting Status</h3>
        <div className="voting-progress">
          <div className="vote-count">
            Votes Cast: {Object.keys(votes).length} / {Object.keys(players).length}
          </div>
          
          <div className="player-vote-status">
            {playerList.map(player => {
              const hasVoted = votes[player.id] !== undefined;
              return (
                <div key={player.id} className="player-status">
                  <span>Seat {player.seat + 1}</span>
                  <span className={`vote-status ${hasVoted ? 'voted' : 'pending'}`}>
                    {hasVoted ? '✓ Voted' : '⏳ Waiting...'}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      {Object.keys(votes).length > 0 && (
        <div className="current-votes">
          <h3>Current Vote Tally</h3>
          <div className="vote-tally">
            {playerList.map(player => {
              const voteCount = getVoteCount(player.id);
              return voteCount > 0 ? (
                <div key={player.id} className="vote-result">
                  <span>Seat {player.seat + 1} (Player {player.id})</span>
                  <span className="vote-count">{voteCount} vote{voteCount !== 1 ? 's' : ''}</span>
                </div>
              ) : null;
            })}
          </div>
        </div>
      )}

      {allPlayersVoted() && (
        <div className="finalize-votes">
          <button 
            onClick={handleFinalizeVotes}
            className="finalize-btn"
          >
            Reveal Results
          </button>
        </div>
      )}

      <div className="voting-instructions">
        <h4>Voting Rules</h4>
        <ul>
          <li>Each player must vote for someone (you cannot vote for yourself)</li>
          <li>The player(s) with the most votes will be eliminated</li>
          <li>If multiple players tie for most votes, all tied players are eliminated</li>
          <li>Villagers win if at least one werewolf is eliminated</li>
          <li>Werewolves win if no werewolves are eliminated</li>
        </ul>
      </div>
    </div>
  );
};