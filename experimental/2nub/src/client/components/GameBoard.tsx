import React from 'react';
import { GameState } from '../../types';

interface GameBoardProps {
  game: GameState | null;
  currentPlayerId: string | null;
  onLeave: () => void;
}

export const GameBoard: React.FC<GameBoardProps> = ({ game, currentPlayerId, onLeave }) => {
  if (!game) {
    return (
      <div style={{
        backgroundColor: 'white',
        padding: '40px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        textAlign: 'center'
      }}>
        <h2>Game not found</h2>
        <p>The game you were in no longer exists.</p>
        <button onClick={onLeave} style={{
          padding: '10px 20px',
          backgroundColor: '#007bff',
          color: 'white',
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer'
        }}>
          Back to Game List
        </button>
      </div>
    );
  }

  const currentPlayer = currentPlayerId ? game.players.find(p => p.id === currentPlayerId) : null;
  const playerList = game.players;

  return (
    <div style={{
      backgroundColor: 'white',
      padding: '30px',
      borderRadius: '8px',
      boxShadow: '0 2px 4px rgba(0,0,0,0.1)'
    }}>
      <div style={{ 
        display: 'flex', 
        justifyContent: 'space-between', 
        alignItems: 'center', 
        marginBottom: '30px',
        paddingBottom: '20px',
        borderBottom: '2px solid #eee'
      }}>
        <div>
          <h1 style={{ margin: '0 0 8px 0', color: '#333' }}>{game.name}</h1>
          <div style={{ display: 'flex', gap: '20px', fontSize: '14px', color: '#666' }}>
            <span>Game ID: <strong>{game.id}</strong></span>
            <span>Players: <strong>{game.players.length}</strong></span>
            <span style={{ 
              padding: '2px 8px', 
              borderRadius: '12px', 
              backgroundColor: game.state.state === 'lobby' ? '#28a745' : '#ffc107',
              color: 'white',
              textTransform: 'capitalize'
            }}>
              {game.state.state === 'lobby' ? 'Waiting' : game.state.state}
            </span>
          </div>
        </div>
      </div>

      {currentPlayer && (
        <div style={{
          backgroundColor: '#f8f9fa',
          padding: '15px',
          borderRadius: '6px',
          marginBottom: '25px',
          border: '2px solid #007bff'
        }}>
          <h3 style={{ margin: '0 0 8px 0', color: '#007bff' }}>You are:</h3>
          <p style={{ margin: 0, fontSize: '16px' }}>
            <strong>{currentPlayer.name}</strong> (Seat {game.players.indexOf(currentPlayer) + 1})
          </p>
        </div>
      )}

      <div style={{ marginBottom: '25px' }}>
        <h3 style={{ marginBottom: '15px', color: '#333' }}>Players in Game:</h3>
        {playerList.length === 0 ? (
          <p style={{ fontStyle: 'italic', color: '#666' }}>No players in the game yet.</p>
        ) : (
          <div style={{ display: 'grid', gap: '10px', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))' }}>
            {playerList.map((player) => (
              <div key={player.id} style={{
                padding: '12px',
                border: `2px solid ${player.id === currentPlayerId ? '#007bff' : '#ddd'}`,
                borderRadius: '6px',
                backgroundColor: player.id === currentPlayerId ? '#f0f8ff' : '#fff',
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center'
              }}>
                <div>
                  <div style={{ fontWeight: 'bold', marginBottom: '4px' }}>
                    {player.name} {player.id === currentPlayerId && '(You)'}
                  </div>
                  <div style={{ fontSize: '14px', color: '#666' }}>
                    Seat {game.players.indexOf(player) + 1}
                  </div>
                </div>
                <div 
                  title={player.connected ? 'Connected' : 'Disconnected'}
                  style={{
                    width: '12px',
                    height: '12px',
                    borderRadius: '50%',
                    backgroundColor: player.connected ? '#28a745' : '#dc3545'
                  }} 
                />
              </div>
            ))}
          </div>
        )}
      </div>

      <div style={{
        backgroundColor: '#f8f9fa',
        padding: '20px',
        borderRadius: '6px',
        textAlign: 'center'
      }}>
        <h3 style={{ margin: '0 0 10px 0', color: '#333' }}>Game Area</h3>
        <p style={{ margin: '0 0 15px 0', color: '#666' }}>
          This is where the actual game would be implemented. The boilerplate provides:
        </p>
        <ul style={{ textAlign: 'left', color: '#666', margin: '0 0 20px 0', paddingLeft: '20px' }}>
          <li>Real-time player connection status</li>
          <li>Game state synchronization via WebSockets</li>
          <li>CRUD operations for games and players</li>
          <li>Clean separation of server and client logic</li>
        </ul>
        <div style={{ 
          padding: '15px', 
          backgroundColor: '#d1ecf1', 
          borderRadius: '4px', 
          color: '#0c5460',
          border: '1px solid #bee5eb'
        }}>
          <strong>Ready for your game logic!</strong> Add your game mechanics, rules, and UI components here.
        </div>
      </div>
    </div>
  );
};