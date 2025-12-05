import React from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState, PlayerState } from '../../server/types';
import { getRoleDefinition } from '../../server/roles';

interface DayPhaseProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID'> {
  currentPlayer: PlayerState | null;
}

const DayPhase: React.FC<DayPhaseProps> = ({ 
  G, 
  ctx, 
  moves, 
  playerID, 
  currentPlayer 
}) => {
  const handleStartVoting = () => {
    if (moves.startVoting) {
      moves.startVoting();
    }
  };

  if (!currentPlayer) {
    return (
      <div style={{ textAlign: 'center', padding: '40px' }}>
        <h2>Day Phase</h2>
        <p>You are not in this game.</p>
      </div>
    );
  }

  const roleDefinition = getRoleDefinition(currentPlayer.role);

  return (
    <div style={{ maxWidth: '800px', margin: '0 auto' }}>
      <div style={{
        backgroundColor: 'white',
        padding: '30px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        marginBottom: '20px'
      }}>
        <h2 style={{ marginTop: 0, textAlign: 'center' }}>Day Phase - Discussion Time</h2>
        
        <div style={{ 
          backgroundColor: '#fff3cd', 
          padding: '20px', 
          borderRadius: '8px',
          marginBottom: '20px',
          textAlign: 'center'
        }}>
          <h3 style={{ margin: '0 0 10px 0' }}>Your Current Role</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#856404' }}>
            {roleDefinition.name}
          </div>
          <div style={{ fontSize: '14px', color: '#666', marginTop: '5px' }}>
            Team: {roleDefinition.team}
          </div>
        </div>

        {currentPlayer.privateLog.length > 0 && (
          <div style={{
            backgroundColor: '#f8f9fa',
            padding: '20px',
            borderRadius: '8px',
            marginBottom: '20px'
          }}>
            <h4>What you learned during the night:</h4>
            {currentPlayer.privateLog.map((log, index) => (
              <p key={index} style={{ margin: '10px 0', fontSize: '16px' }}>
                • {log}
              </p>
            ))}
          </div>
        )}

        <div style={{
          backgroundColor: '#d1ecf1',
          padding: '20px',
          borderRadius: '8px',
          marginBottom: '20px'
        }}>
          <h4>Discussion Phase Instructions</h4>
          <ul style={{ margin: '10px 0', paddingLeft: '20px' }}>
            <li>Discuss what you learned during the night (or bluff!)</li>
            <li>Try to figure out who the werewolves are</li>
            <li>Remember: roles may have been swapped during the night</li>
            <li>When ready, anyone can start the voting phase</li>
          </ul>
        </div>

        <div style={{
          backgroundColor: '#f8f9fa',
          padding: '20px',
          borderRadius: '8px',
          marginBottom: '20px'
        }}>
          <h4>All Players</h4>
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))',
            gap: '15px',
            marginTop: '15px'
          }}>
            {Object.values(G.players)
              .sort((a, b) => a.seat - b.seat)
              .map(player => (
                <div
                  key={player.id}
                  style={{
                    padding: '15px',
                    backgroundColor: player.id === playerID ? '#e3f2fd' : 'white',
                    borderRadius: '4px',
                    border: player.id === playerID ? '2px solid #007bff' : '1px solid #dee2e6'
                  }}
                >
                  <div style={{ fontWeight: 'bold', marginBottom: '5px' }}>
                    {player.name}
                  </div>
                  <div style={{ fontSize: '14px', color: '#666' }}>
                    Seat {player.seat}
                  </div>
                  {player.id === playerID && (
                    <div style={{ fontSize: '12px', color: '#007bff', marginTop: '5px' }}>
                      (You)
                    </div>
                  )}
                </div>
              ))}
          </div>
        </div>

        <div style={{ textAlign: 'center' }}>
          <button
            onClick={handleStartVoting}
            style={{
              padding: '15px 30px',
              backgroundColor: '#dc3545',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              fontSize: '18px',
              fontWeight: 'bold',
              cursor: 'pointer'
            }}
          >
            Start Voting
          </button>
          <p style={{ fontSize: '14px', color: '#666', marginTop: '10px' }}>
            Any player can start the voting phase when discussion is complete
          </p>
        </div>
      </div>
    </div>
  );
};

export default DayPhase;