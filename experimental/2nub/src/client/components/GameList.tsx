import React, { useState } from 'react';
import { GameState } from '../../types';

interface GameListProps {
  games: GameState[];
  onJoinGame: (gameId: string, playerName: string) => void;
  onRefresh: () => void;
}

export const GameList: React.FC<GameListProps> = ({ games, onJoinGame, onRefresh }) => {
  const [playerName, setPlayerName] = useState('');
  const [joiningGameId, setJoiningGameId] = useState<string | null>(null);

  const handleJoinClick = (gameId: string) => {
    setJoiningGameId(gameId);
  };

  const handleJoinSubmit = (e: React.FormEvent, gameId: string) => {
    e.preventDefault();
    if (playerName.trim()) {
      onJoinGame(gameId, playerName.trim());
      setPlayerName('');
      setJoiningGameId(null);
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'waiting': return '#28a745';
      case 'playing': return '#ffc107';
      case 'finished': return '#6c757d';
      default: return '#6c757d';
    }
  };

  return (
    <div style={{
      backgroundColor: 'white',
      padding: '20px',
      borderRadius: '8px',
      boxShadow: '0 2px 4px rgba(0,0,0,0.1)'
    }}>
      <div style={{ 
        display: 'flex', 
        justifyContent: 'space-between', 
        alignItems: 'center', 
        marginBottom: '20px' 
      }}>
        <h2 style={{ margin: 0, color: '#333' }}>Available Games</h2>
        <button
          onClick={onRefresh}
          style={{
            padding: '8px 16px',
            backgroundColor: '#6c757d',
            color: 'white',
            border: 'none',
            borderRadius: '4px',
            cursor: 'pointer'
          }}
        >
          Refresh
        </button>
      </div>

      {games.length === 0 ? (
        <p style={{ textAlign: 'center', color: '#666', fontStyle: 'italic' }}>
          No games available. Create one to get started!
        </p>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '15px' }}>
          {games.map((game) => (
            <div key={game.id} style={{
              border: '1px solid #ddd',
              borderRadius: '4px',
              padding: '15px',
              backgroundColor: '#f8f9fa'
            }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div style={{ flex: 1 }}>
                  <h3 style={{ margin: '0 0 8px 0', color: '#333' }}>{game.name}</h3>
                  <div style={{ display: 'flex', gap: '15px', marginBottom: '10px' }}>
                    <span style={{ fontSize: '14px', color: '#666' }}>
                      ID: <strong>{game.id}</strong>
                    </span>
                    <span style={{ fontSize: '14px', color: '#666' }}>
                      Players: <strong>{Object.keys(game.players).length}/{game.maxPlayers}</strong>
                    </span>
                    <span style={{ 
                      fontSize: '12px', 
                      padding: '2px 8px', 
                      borderRadius: '12px', 
                      backgroundColor: getStatusColor(game.status),
                      color: 'white',
                      textTransform: 'capitalize'
                    }}>
                      {game.status}
                    </span>
                  </div>
                  
                  {Object.keys(game.players).length > 0 && (
                    <div style={{ marginBottom: '10px' }}>
                      <strong style={{ fontSize: '14px' }}>Players:</strong>
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '5px', marginTop: '5px' }}>
                        {Object.values(game.players).map((player) => (
                          <span key={player.id} style={{
                            fontSize: '12px',
                            padding: '2px 6px',
                            backgroundColor: player.connected ? '#d4edda' : '#f8d7da',
                            color: player.connected ? '#155724' : '#721c24',
                            borderRadius: '4px',
                            border: `1px solid ${player.connected ? '#c3e6cb' : '#f5c6cb'}`
                          }}>
                            {player.name} (Seat {player.seat})
                          </span>
                        ))}
                      </div>
                    </div>
                  )}
                </div>

                <div style={{ marginLeft: '20px' }}>
                  {joiningGameId === game.id ? (
                    <form onSubmit={(e) => handleJoinSubmit(e, game.id)} style={{ display: 'flex', gap: '8px' }}>
                      <input
                        type="text"
                        value={playerName}
                        onChange={(e) => setPlayerName(e.target.value)}
                        placeholder="Your name"
                        style={{
                          padding: '6px 10px',
                          border: '1px solid #ddd',
                          borderRadius: '4px',
                          fontSize: '14px',
                          width: '120px'
                        }}
                        required
                        autoFocus
                      />
                      <button
                        type="submit"
                        style={{
                          padding: '6px 12px',
                          backgroundColor: '#28a745',
                          color: 'white',
                          border: 'none',
                          borderRadius: '4px',
                          fontSize: '14px',
                          cursor: 'pointer'
                        }}
                      >
                        Join
                      </button>
                      <button
                        type="button"
                        onClick={() => setJoiningGameId(null)}
                        style={{
                          padding: '6px 12px',
                          backgroundColor: '#6c757d',
                          color: 'white',
                          border: 'none',
                          borderRadius: '4px',
                          fontSize: '14px',
                          cursor: 'pointer'
                        }}
                      >
                        Cancel
                      </button>
                    </form>
                  ) : (
                    <button
                      onClick={() => handleJoinClick(game.id)}
                      disabled={Object.keys(game.players).length >= game.maxPlayers || game.status !== 'waiting'}
                      style={{
                        padding: '8px 16px',
                        backgroundColor: Object.keys(game.players).length >= game.maxPlayers || game.status !== 'waiting' ? '#6c757d' : '#28a745',
                        color: 'white',
                        border: 'none',
                        borderRadius: '4px',
                        fontSize: '14px',
                        cursor: Object.keys(game.players).length >= game.maxPlayers || game.status !== 'waiting' ? 'not-allowed' : 'pointer'
                      }}
                    >
                      {Object.keys(game.players).length >= game.maxPlayers ? 'Full' : 
                       game.status !== 'waiting' ? 'In Progress' : 'Join'}
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};