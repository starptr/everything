import React from 'react';
import { GameState } from '../../../src/shared/types';

interface RevealPhaseProps {
  gameState: GameState;
  moves: any;
}

export const RevealPhase: React.FC<RevealPhaseProps> = ({ gameState, moves }) => {
  const { revealed, players, center } = gameState;
  
  if (!revealed) {
    return <div>Loading results...</div>;
  }

  const { winners, endSummary } = revealed;
  
  const playerList = Object.values(players).sort((a, b) => a.seat - b.seat);

  const handlePlayAgain = () => {
    // This would reset the game to lobby phase
    // Implementation depends on how you want to handle game resets
    console.log('Play again clicked');
  };

  const isWinner = (playerId: string): boolean => {
    return winners.includes(playerId);
  };

  const getVoteCount = (playerId: string): number => {
    return Object.values(endSummary.votes).filter(vote => vote === playerId).length;
  };

  return (
    <div className="reveal-phase">
      <div className="phase-header">
        <h2>Game Over - Results Revealed!</h2>
        <div className="win-condition">
          <h3>{endSummary.winCondition}</h3>
        </div>
      </div>

      <div className="winners-section">
        <h3>Winners</h3>
        <div className="winners-list">
          {winners.map(winnerId => {
            const winner = players[winnerId];
            return (
              <div key={winnerId} className="winner-card">
                <div className="seat">Seat {winner.seat + 1}</div>
                <div className="player-id">Player {winnerId}</div>
                <div className="final-role">{endSummary.finalRoles[winnerId]}</div>
                <div className="winner-label">🏆 Winner</div>
              </div>
            );
          })}
        </div>
      </div>

      <div className="game-summary">
        <h3>Final Results</h3>
        
        <div className="vote-results">
          <h4>Vote Results</h4>
          <div className="eliminated-players">
            <strong>Eliminated Players:</strong>
            {endSummary.eliminatedPlayers.length > 0 ? (
              <div className="eliminated-list">
                {endSummary.eliminatedPlayers.map(playerId => {
                  const player = players[playerId];
                  const voteCount = getVoteCount(playerId);
                  return (
                    <div key={playerId} className="eliminated-player">
                      Seat {player.seat + 1} (Player {playerId}) - {voteCount} votes
                    </div>
                  );
                })}
              </div>
            ) : (
              <div>No one was eliminated (tie vote or no votes)</div>
            )}
          </div>
        </div>

        <div className="role-reveals">
          <h4>Role Reveals</h4>
          <div className="player-roles">
            {playerList.map(player => {
              const originalRole = endSummary.originalRoles[player.id];
              const finalRole = endSummary.finalRoles[player.id];
              const roleChanged = originalRole !== finalRole;
              const wasEliminated = endSummary.eliminatedPlayers.includes(player.id);
              const wonGame = isWinner(player.id);
              
              return (
                <div 
                  key={player.id} 
                  className={`player-role-card ${wasEliminated ? 'eliminated' : ''} ${wonGame ? 'winner' : ''}`}
                >
                  <div className="player-info">
                    <div className="seat">Seat {player.seat + 1}</div>
                    <div className="player-id">Player {player.id}</div>
                  </div>
                  
                  <div className="role-info">
                    {roleChanged ? (
                      <div className="role-change">
                        <div className="original-role">Started as: {originalRole}</div>
                        <div className="arrow">→</div>
                        <div className="final-role">Ended as: {finalRole}</div>
                      </div>
                    ) : (
                      <div className="unchanged-role">
                        Role: {finalRole}
                      </div>
                    )}
                  </div>

                  <div className="game-result">
                    {wasEliminated && <div className="eliminated-badge">💀 Eliminated</div>}
                    {wonGame && <div className="winner-badge">🏆 Winner</div>}
                  </div>

                  <div className="vote-info">
                    Votes received: {getVoteCount(player.id)}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <div className="center-cards">
          <h4>Center Cards</h4>
          <div className="center-card-list">
            {center.map((role, index) => (
              <div key={index} className="center-card">
                Center {index + 1}: {role}
              </div>
            ))}
          </div>
        </div>

        <div className="voting-breakdown">
          <h4>Voting Breakdown</h4>
          <div className="vote-breakdown">
            {Object.entries(endSummary.votes).map(([voter, target]) => {
              const voterPlayer = players[voter];
              const targetPlayer = players[target];
              return (
                <div key={voter} className="vote-entry">
                  Seat {voterPlayer.seat + 1} voted for Seat {targetPlayer.seat + 1}
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <div className="game-actions">
        <button 
          onClick={handlePlayAgain}
          className="play-again-btn"
        >
          Play Again
        </button>
      </div>
    </div>
  );
};