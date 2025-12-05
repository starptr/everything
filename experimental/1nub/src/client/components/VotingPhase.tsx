import React, { useState } from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState, PlayerState } from '../../server/types';

interface VotingPhaseProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID'> {
  currentPlayer: PlayerState | null;
}

const VotingPhase: React.FC<VotingPhaseProps> = ({ 
  G, 
  ctx, 
  moves, 
  playerID, 
  currentPlayer 
}) => {
  const [selectedTarget, setSelectedTarget] = useState<string>('');

  const handleCastVote = () => {
    if (selectedTarget && moves.castVote) {
      moves.castVote({ target: selectedTarget });
    }
  };

  if (!currentPlayer) {
    return (
      <div style={{ textAlign: 'center', padding: '40px' }}>
        <h2>Voting Phase</h2>
        <p>You are not in this game.</p>
      </div>
    );
  }

  const hasVoted = playerID ? G.votes[playerID] !== undefined : false;
  const currentVote = playerID ? G.votes[playerID] : null;
  const totalPlayers = Object.keys(G.players).length;
  const totalVotes = Object.keys(G.votes).length;

  const allPlayers = Object.values(G.players).sort((a, b) => a.seat - b.seat);

  return (
    <div style={{ maxWidth: '800px', margin: '0 auto' }}>
      <div style={{
        backgroundColor: 'white',
        padding: '30px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        marginBottom: '20px'
      }}>
        <h2 style={{ marginTop: 0, textAlign: 'center' }}>Voting Phase</h2>
        
        <div style={{ 
          backgroundColor: '#f8d7da', 
          padding: '20px', 
          borderRadius: '8px',
          marginBottom: '20px',
          textAlign: 'center'
        }}>
          <h3 style={{ margin: '0 0 10px 0' }}>Time to Vote!</h3>
          <p style={{ margin: '0', fontSize: '16px' }}>
            Vote for the player you think is a werewolf.<br/>
            The player(s) with the most votes will be eliminated.
          </p>
        </div>

        <div style={{ marginBottom: '20px', textAlign: 'center' }}>
          <p><strong>Votes cast: {totalVotes} / {totalPlayers}</strong></p>
        </div>

        {hasVoted ? (
          <div style={{
            backgroundColor: '#d1ecf1',
            padding: '20px',
            borderRadius: '8px',
            marginBottom: '20px',
            textAlign: 'center'
          }}>
            <h3>You voted for: {G.players[currentVote!].name}</h3>
            <p>Waiting for other players to vote...</p>
          </div>
        ) : (
          <div>
            <h3>Cast Your Vote</h3>
            <div style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(250px, 1fr))',
              gap: '15px',
              marginBottom: '20px'
            }}>
              {allPlayers.map(player => (
                <button
                  key={player.id}
                  onClick={() => setSelectedTarget(player.id)}
                  style={{
                    padding: '20px',
                    border: selectedTarget === player.id 
                      ? '3px solid #dc3545' : '1px solid #ccc',
                    borderRadius: '8px',
                    backgroundColor: selectedTarget === player.id
                      ? '#f8d7da' : 'white',
                    cursor: 'pointer',
                    textAlign: 'left',
                    transition: 'all 0.2s'
                  }}
                >
                  <div style={{ 
                    fontWeight: 'bold', 
                    fontSize: '18px',
                    marginBottom: '5px'
                  }}>
                    {player.name}
                  </div>
                  <div style={{ fontSize: '14px', color: '#666' }}>
                    Seat {player.seat}
                  </div>
                  {player.id === playerID && (
                    <div style={{ 
                      fontSize: '12px', 
                      color: '#007bff', 
                      marginTop: '5px',
                      fontWeight: 'bold'
                    }}>
                      (This is you!)
                    </div>
                  )}
                </button>
              ))}
            </div>

            <div style={{ textAlign: 'center' }}>
              <button
                onClick={handleCastVote}
                disabled={!selectedTarget}
                style={{
                  padding: '15px 30px',
                  backgroundColor: selectedTarget ? '#dc3545' : '#6c757d',
                  color: 'white',
                  border: 'none',
                  borderRadius: '4px',
                  fontSize: '18px',
                  fontWeight: 'bold',
                  cursor: selectedTarget ? 'pointer' : 'not-allowed'
                }}
              >
                Cast Vote
              </button>
            </div>
          </div>
        )}

        <div style={{
          backgroundColor: '#f8f9fa',
          padding: '20px',
          borderRadius: '8px',
          marginTop: '20px'
        }}>
          <h4>Vote Status</h4>
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))',
            gap: '10px',
            marginTop: '10px'
          }}>
            {allPlayers.map(player => (
              <div
                key={player.id}
                style={{
                  padding: '10px',
                  backgroundColor: 'white',
                  borderRadius: '4px',
                  border: '1px solid #dee2e6',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center'
                }}
              >
                <span>{player.name}</span>
                <span style={{
                  padding: '2px 8px',
                  borderRadius: '12px',
                  fontSize: '12px',
                  backgroundColor: G.votes[player.id] ? '#28a745' : '#6c757d',
                  color: 'white'
                }}>
                  {G.votes[player.id] ? '✓' : '○'}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
};

export default VotingPhase;