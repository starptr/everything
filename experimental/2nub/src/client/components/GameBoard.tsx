import React, { useState } from 'react';
import { GameStateClient } from '../../types';
import { Onub } from './Onub';

interface GameBoardProps {
  game: GameStateClient | null;
  gameId: string | null;
  currentPlayerId: string | null;
  onLeave: () => void;
  onForceDisconnect: (playerId: string) => void;
}

export const GameBoard: React.FC<GameBoardProps> = ({ game, gameId, currentPlayerId, onLeave, onForceDisconnect }) => {
  console.debug("Rendering GameBoard with game:", game);
  const [disconnectingPlayerId, setDisconnectingPlayerId] = useState<string | null>(null);

  const handleForceDisconnect = (playerId: string, playerName: string) => {
    const confirmed = window.confirm(`Are you sure you want to force disconnect ${playerName}? They will be able to rejoin later.`);
    if (confirmed) {
      setDisconnectingPlayerId(playerId);
      onForceDisconnect(playerId);
      setTimeout(() => setDisconnectingPlayerId(null), 1000);
    }
  };

  if (!game) {
    // If we have a gameId but no game data, show loading state
    if (gameId) {
      return (
        <div style={{
          backgroundColor: 'white',
          padding: '40px',
          borderRadius: '8px',
          boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
          textAlign: 'center'
        }}>
          <h2>Loading game...</h2>
          <p>Connecting to game and loading data...</p>
          <div style={{
            margin: '20px auto',
            width: '40px',
            height: '40px',
            border: '4px solid #f3f3f3',
            borderTop: '4px solid #007bff',
            borderRadius: '50%',
            animation: 'spin 1s linear infinite'
          }} />
          <style>{`
            @keyframes spin {
              0% { transform: rotate(0deg); }
              100% { transform: rotate(360deg); }
            }
          `}</style>
          <button onClick={onLeave} style={{
            padding: '10px 20px',
            backgroundColor: '#6c757d',
            color: 'white',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer',
            marginTop: '20px'
          }}>
            Cancel
          </button>
        </div>
      );
    }
    
    // No gameId means the game doesn't exist
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
  console.debug("Game:", game);

  const currentPlayer = currentPlayerId ? game.players.find(p => p.id === currentPlayerId) : null;
  const playerList = game.players;
  const isCurrentPlayerDisconnected = currentPlayer && !currentPlayer.connected;

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
            <span>Game ID: <strong>{gameId}</strong></span>
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

      {isCurrentPlayerDisconnected && (
        <div style={{
          backgroundColor: '#f8d7da',
          border: '2px solid #f5c6cb',
          borderRadius: '6px',
          padding: '15px',
          marginBottom: '20px',
          color: '#721c24'
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
            <div style={{
              width: '20px',
              height: '20px',
              borderRadius: '50%',
              backgroundColor: '#dc3545'
            }} />
            <div>
              <strong>You are currently disconnected</strong>
              <p style={{ margin: '5px 0 0 0', fontSize: '14px' }}>
                Trying to reconnect... You can refresh the page or use the rejoin feature if needed.
              </p>
            </div>
          </div>
        </div>
      )}

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
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  {player.connected && player.id !== currentPlayerId && (
                    <button
                      onClick={() => handleForceDisconnect(player.id, player.name)}
                      disabled={disconnectingPlayerId === player.id}
                      style={{
                        padding: '4px 8px',
                        fontSize: '12px',
                        backgroundColor: disconnectingPlayerId === player.id ? '#6c757d' : '#dc3545',
                        color: 'white',
                        border: 'none',
                        borderRadius: '4px',
                        cursor: disconnectingPlayerId === player.id ? 'not-allowed' : 'pointer',
                        opacity: disconnectingPlayerId === player.id ? 0.7 : 1
                      }}
                      title="Force disconnect this player"
                    >
                      {disconnectingPlayerId === player.id ? '...' : 'Disconnect'}
                    </button>
                  )}
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
              </div>
            ))}
          </div>
        )}
      </div>

      {currentPlayerId && <Onub game={game} currentPlayerId={currentPlayerId} />}
    </div>
  );
};