import React from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState } from '../../server/types';
import { getRoleDefinition } from '../../server/roles';

interface RevealPhaseProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID'> {}

const RevealPhase: React.FC<RevealPhaseProps> = ({ G, ctx, moves, playerID }) => {
  const handleResetGame = () => {
    if (moves.resetGame) {
      moves.resetGame();
    }
  };

  if (!G.revealed) {
    return (
      <div style={{ textAlign: 'center', padding: '40px' }}>
        <h2>Calculating Results...</h2>
      </div>
    );
  }

  const { winners, endSummary } = G.revealed;
  const isWinner = playerID ? winners.includes(playerID) : false;

  const sortedPlayers = Object.values(G.players).sort((a, b) => a.seat - b.seat);

  return (
    <div style={{ maxWidth: '1000px', margin: '0 auto' }}>
      <div style={{
        backgroundColor: 'white',
        padding: '30px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        marginBottom: '20px'
      }}>
        <h2 style={{ marginTop: 0, textAlign: 'center' }}>Game Results</h2>
        
        <div style={{ 
          backgroundColor: isWinner ? '#d4edda' : '#f8d7da', 
          padding: '30px', 
          borderRadius: '8px',
          marginBottom: '30px',
          textAlign: 'center',
          border: `3px solid ${isWinner ? '#28a745' : '#dc3545'}`
        }}>
          <h3 style={{ 
            margin: '0 0 15px 0',
            fontSize: '2rem',
            color: isWinner ? '#155724' : '#721c24'
          }}>
            {isWinner ? '🎉 You Win! 🎉' : '💀 You Lose 💀'}
          </h3>
          <p style={{ 
            margin: '0',
            fontSize: '18px',
            color: isWinner ? '#155724' : '#721c24'
          }}>
            {endSummary.winCondition}
          </p>
        </div>

        <div style={{ marginBottom: '30px' }}>
          <h3>Vote Results</h3>
          <div style={{
            backgroundColor: '#f8f9fa',
            padding: '20px',
            borderRadius: '8px'
          }}>
            {Object.entries(endSummary.voteTally)
              .sort(([,a], [,b]) => b - a)
              .map(([playerId, votes]) => {
                const player = G.players[playerId];
                const isEliminated = endSummary.eliminatedPlayers.includes(playerId);
                return (
                  <div
                    key={playerId}
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                      padding: '10px 0',
                      borderBottom: '1px solid #dee2e6',
                      backgroundColor: isEliminated ? '#f8d7da' : 'transparent'
                    }}
                  >
                    <span style={{ fontWeight: isEliminated ? 'bold' : 'normal' }}>
                      {player.name} {isEliminated && '(ELIMINATED)'}
                    </span>
                    <span style={{ 
                      padding: '4px 8px',
                      borderRadius: '12px',
                      backgroundColor: votes > 0 ? '#dc3545' : '#6c757d',
                      color: 'white',
                      fontSize: '14px'
                    }}>
                      {votes} votes
                    </span>
                  </div>
                );
              })}
          </div>
        </div>

        <div style={{ marginBottom: '30px' }}>
          <h3>Final Roles</h3>
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
            gap: '15px'
          }}>
            {sortedPlayers.map(player => {
              const finalRole = endSummary.finalRoles[player.id];
              const originalRole = player.originalRole;
              const roleDefinition = getRoleDefinition(finalRole);
              const originalRoleDefinition = getRoleDefinition(originalRole);
              const roleChanged = finalRole !== originalRole;
              const isEliminated = endSummary.eliminatedPlayers.includes(player.id);
              const isWinnerPlayer = winners.includes(player.id);

              return (
                <div
                  key={player.id}
                  style={{
                    padding: '20px',
                    borderRadius: '8px',
                    border: `2px solid ${
                      isEliminated ? '#dc3545' : 
                      isWinnerPlayer ? '#28a745' : '#dee2e6'
                    }`,
                    backgroundColor: isEliminated ? '#f8d7da' : 
                                   isWinnerPlayer ? '#d4edda' : 'white'
                  }}
                >
                  <div style={{ 
                    fontWeight: 'bold', 
                    fontSize: '18px',
                    marginBottom: '10px'
                  }}>
                    {player.name}
                    {player.id === playerID && ' (You)'}
                  </div>
                  
                  <div style={{ marginBottom: '10px' }}>
                    <div style={{ fontSize: '14px', color: '#666' }}>
                      Started as: {originalRoleDefinition.name}
                    </div>
                    <div style={{ 
                      fontSize: '16px', 
                      fontWeight: 'bold',
                      color: roleChanged ? '#fd7e14' : '#333'
                    }}>
                      Ended as: {roleDefinition.name}
                      {roleChanged && ' ⚡'}
                    </div>
                    <div style={{ fontSize: '14px', color: '#666' }}>
                      Team: {roleDefinition.team}
                    </div>
                  </div>

                  <div style={{
                    fontSize: '12px',
                    padding: '5px',
                    borderRadius: '4px',
                    backgroundColor: isEliminated ? '#721c24' :
                                   isWinnerPlayer ? '#155724' : '#6c757d',
                    color: 'white',
                    textAlign: 'center'
                  }}>
                    {isEliminated ? 'ELIMINATED' :
                     isWinnerPlayer ? 'WINNER' : 'SURVIVOR'}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <div style={{ marginBottom: '30px' }}>
          <h3>Center Cards</h3>
          <div style={{
            display: 'flex',
            gap: '15px',
            justifyContent: 'center'
          }}>
            {G.center.map((roleId, index) => {
              const roleDefinition = getRoleDefinition(roleId);
              return (
                <div
                  key={index}
                  style={{
                    padding: '15px',
                    backgroundColor: '#f8f9fa',
                    borderRadius: '8px',
                    border: '1px solid #dee2e6',
                    textAlign: 'center'
                  }}
                >
                  <div style={{ fontWeight: 'bold' }}>Center {index + 1}</div>
                  <div>{roleDefinition.name}</div>
                </div>
              );
            })}
          </div>
        </div>

        <div style={{ textAlign: 'center' }}>
          <button
            onClick={handleResetGame}
            style={{
              padding: '15px 30px',
              backgroundColor: '#007bff',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              fontSize: '18px',
              fontWeight: 'bold',
              cursor: 'pointer'
            }}
          >
            Play Again
          </button>
        </div>
      </div>
    </div>
  );
};

export default RevealPhase;