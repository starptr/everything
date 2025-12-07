import React, { useState } from 'react';
import { GameState } from '../../types';

interface GameListProps {
  games: GameState[];
  onJoinGame: (gameId: string, playerName?: string, existingPlayerId?: string) => void;
  onRefresh: () => void;
}

export const GameList: React.FC<GameListProps> = ({ games, onJoinGame, onRefresh }) => {
  const [playerName, setPlayerName] = useState('');
  const [joiningGameId, setJoiningGameId] = useState<string | null>(null);
  const [selectedExistingPlayer, setSelectedExistingPlayer] = useState<string | null>(null);

  const handleJoinClick = (gameId: string) => {
    setJoiningGameId(gameId);
    setSelectedExistingPlayer(null);
    setPlayerName('');
  };

  const handleJoinSubmit = (e: React.FormEvent, gameId: string) => {
    e.preventDefault();
    if (selectedExistingPlayer) {
      onJoinGame(gameId, undefined, selectedExistingPlayer);
    } else if (playerName.trim()) {
      onJoinGame(gameId, playerName.trim());
    }
    setPlayerName('');
    setJoiningGameId(null);
    setSelectedExistingPlayer(null);
  };

  const handleExistingPlayerSelect = (playerId: string) => {
    setSelectedExistingPlayer(playerId);
    setPlayerName('');
  };

  const handleNewPlayerSelect = () => {
    setSelectedExistingPlayer(null);
  };

  const getStatusColor = (state: string) => {
    switch (state) {
      case 'lobby': return '#28a745';
      case 'night':
      case 'day':
      case 'voting': return '#ffc107';
      case 'finished': return '#6c757d';
      default: return '#6c757d';
    }
  };

  const getStatusDisplayName = (state: string) => {
    switch (state) {
      case 'lobby': return 'Waiting';
      case 'night': return 'Night Phase';
      case 'day': return 'Day Phase';
      case 'voting': return 'Voting';
      case 'finished': return 'Finished';
      default: return state;
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
                      Players: <strong>{game.players.length}</strong>
                    </span>
                    <span style={{ 
                      fontSize: '12px', 
                      padding: '2px 8px', 
                      borderRadius: '12px', 
                      backgroundColor: getStatusColor(game.state.state),
                      color: 'white',
                      textTransform: 'capitalize'
                    }}>
                      {getStatusDisplayName(game.state.state)}
                    </span>
                  </div>
                  
                  {game.players.length > 0 && (
                    <div style={{ marginBottom: '10px' }}>
                      <strong style={{ fontSize: '14px' }}>Players:</strong>
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '5px', marginTop: '5px' }}>
                        {game.players.map((player) => (
                          <span key={player.id} style={{
                            fontSize: '12px',
                            padding: '2px 6px',
                            backgroundColor: player.connected ? '#d4edda' : '#f8d7da',
                            color: player.connected ? '#155724' : '#721c24',
                            borderRadius: '4px',
                            border: `1px solid ${player.connected ? '#c3e6cb' : '#f5c6cb'}`
                          }}>
                            {player.name} (Seat {game.players.indexOf(player) + 1})
                          </span>
                        ))}
                      </div>
                    </div>
                  )}
                </div>

                <div style={{ marginLeft: '20px' }}>
                  {joiningGameId === game.id ? (
                    <div style={{ minWidth: '300px' }}>
                      {(() => {
                        const disconnectedPlayers = game.players.filter(p => !p.connected);
                        return (
                          <form onSubmit={(e) => handleJoinSubmit(e, game.id)} style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                            {disconnectedPlayers.length > 0 && (
                              <div style={{ marginBottom: '8px' }}>
                                <div style={{ fontSize: '14px', fontWeight: 'bold', marginBottom: '4px' }}>
                                  Join as disconnected player:
                                </div>
                                <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                                  {disconnectedPlayers.map((player) => (
                                    <label key={player.id} style={{ display: 'flex', alignItems: 'center', gap: '6px', cursor: 'pointer' }}>
                                      <input
                                        type="radio"
                                        name="joinOption"
                                        value={player.id}
                                        checked={selectedExistingPlayer === player.id}
                                        onChange={() => handleExistingPlayerSelect(player.id)}
                                      />
                                      <span style={{ fontSize: '14px' }}>
                                        {player.name} (Seat {game.players.indexOf(player) + 1})
                                      </span>
                                    </label>
                                  ))}
                                </div>
                              </div>
                            )}
                            
                            <div style={{ borderTop: disconnectedPlayers.length > 0 ? '1px solid #ddd' : 'none', paddingTop: disconnectedPlayers.length > 0 ? '8px' : '0' }}>
                              <label style={{ display: 'flex', alignItems: 'center', gap: '6px', marginBottom: '8px', cursor: 'pointer' }}>
                                <input
                                  type="radio"
                                  name="joinOption"
                                  value="new"
                                  checked={selectedExistingPlayer === null}
                                  onChange={handleNewPlayerSelect}
                                />
                                <span style={{ fontSize: '14px', fontWeight: 'bold' }}>
                                  Join as new player:
                                </span>
                              </label>
                              <input
                                type="text"
                                value={playerName}
                                onChange={(e) => setPlayerName(e.target.value)}
                                placeholder="Your name"
                                disabled={selectedExistingPlayer !== null}
                                style={{
                                  padding: '6px 10px',
                                  border: '1px solid #ddd',
                                  borderRadius: '4px',
                                  fontSize: '14px',
                                  width: '200px',
                                  backgroundColor: selectedExistingPlayer !== null ? '#f5f5f5' : 'white'
                                }}
                                required={selectedExistingPlayer === null}
                              />
                            </div>
                            
                            <div style={{ display: 'flex', gap: '8px', marginTop: '8px' }}>
                              <button
                                type="submit"
                                disabled={!selectedExistingPlayer && !playerName.trim()}
                                style={{
                                  padding: '6px 12px',
                                  backgroundColor: (!selectedExistingPlayer && !playerName.trim()) ? '#6c757d' : '#28a745',
                                  color: 'white',
                                  border: 'none',
                                  borderRadius: '4px',
                                  fontSize: '14px',
                                  cursor: (!selectedExistingPlayer && !playerName.trim()) ? 'not-allowed' : 'pointer'
                                }}
                              >
                                Join
                              </button>
                              <button
                                type="button"
                                onClick={() => {
                                  setJoiningGameId(null);
                                  setSelectedExistingPlayer(null);
                                  setPlayerName('');
                                }}
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
                            </div>
                          </form>
                        );
                      })()}
                    </div>
                  ) : (
                    <button
                      onClick={() => handleJoinClick(game.id)}
                      disabled={game.state.state !== 'lobby'}
                      style={{
                        padding: '8px 16px',
                        backgroundColor: game.state.state !== 'lobby' ? '#6c757d' : '#28a745',
                        color: 'white',
                        border: 'none',
                        borderRadius: '4px',
                        fontSize: '14px',
                        cursor: game.state.state !== 'lobby' ? 'not-allowed' : 'pointer'
                      }}
                    >
                      {game.state.state !== 'lobby' ? 'In Progress' : 'Join'}
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