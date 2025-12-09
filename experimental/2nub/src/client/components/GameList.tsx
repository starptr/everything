import React, { useState } from 'react';
import { GameState } from '../../types';
import '../styles/main.scss';

interface GameListProps {
  games: GameState[];
  onJoinGame: (gameId: string, playerName: string) => void;
  onRejoinGame: (gameId: string, playerId: string) => Promise<boolean>;
  onRefresh: () => void;
}

export const GameList: React.FC<GameListProps> = ({ games, onJoinGame, onRejoinGame, onRefresh }) => {
  const [playerName, setPlayerName] = useState('');
  const [joiningGameId, setJoiningGameId] = useState<string | null>(null);
  const [selectedExistingPlayer, setSelectedExistingPlayer] = useState<string | null>(null);

  const handleJoinClick = (gameId: string) => {
    setJoiningGameId(gameId);
    setSelectedExistingPlayer(null);
    setPlayerName('');
  };

  const handleJoinSubmit = async (e: React.FormEvent, gameId: string) => {
    e.preventDefault();
    if (selectedExistingPlayer) {
      const success = await onRejoinGame(gameId, selectedExistingPlayer);
      if (success) {
        setPlayerName('');
        setJoiningGameId(null);
        setSelectedExistingPlayer(null);
      }
    } else if (playerName.trim()) {
      onJoinGame(gameId, playerName.trim());
      setPlayerName('');
      setJoiningGameId(null);
      setSelectedExistingPlayer(null);
    }
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

  const getStatusClass = (state: string) => {
    switch (state) {
      case 'lobby': return 'waiting';
      case 'night':
      case 'day':
      case 'voting': return 'night';
      case 'finished': return 'finished';
      default: return 'finished';
    }
  };

  return (
    <div className="game-list">
      <div className="header">
        <h2>Available Games</h2>
        <button onClick={onRefresh} className="button--secondary">
          Refresh
        </button>
      </div>

      {games.length === 0 ? (
        <p className="empty-state">
          No games available. Create one to get started!
        </p>
      ) : (
        <div className="games-container">
          {games.map((game) => (
            <div key={game.id} className="game-card">
              <div className="game-content">
                <div className="game-info">
                  <h3>{game.name}</h3>
                  <div className="game-meta">
                    <span>
                      ID: <strong>{game.id}</strong>
                    </span>
                    <span>
                      Players: <strong>{game.state.players.length}</strong>
                    </span>
                    <span className={`status-badge ${getStatusClass(game.state.state)}`}>
                      {getStatusDisplayName(game.state.state)}
                    </span>
                  </div>
                  
                  {game.state.players.length > 0 && (
                    <div className="players-section">
                      <strong>Players:</strong>
                      <div className="player-badges">
                        {game.state.players.map((player) => (
                          <span key={player.id} className={`player-badge ${player.connected ? 'connected' : 'disconnected'}`}>
                            {player.name} (Seat {game.state.players.indexOf(player) + 1})
                          </span>
                        ))}
                      </div>
                    </div>
                  )}
                </div>

                <div className="game-actions">
                  {joiningGameId === game.id ? (
                    <div className="join-form">
                      {(() => {
                        const disconnectedPlayers = game.state.players.filter(p => !p.connected);
                        return (
                          <form onSubmit={(e) => handleJoinSubmit(e, game.id)} className="form">
                            {disconnectedPlayers.length > 0 && (
                              <div className="existing-players">
                                <div className="section-title">
                                  Join as disconnected player:
                                </div>
                                <div className="radio-group">
                                  {disconnectedPlayers.map((player) => (
                                    <label key={player.id} className="radio-option">
                                      <input
                                        type="radio"
                                        name="joinOption"
                                        value={player.id}
                                        checked={selectedExistingPlayer === player.id}
                                        onChange={() => handleExistingPlayerSelect(player.id)}
                                      />
                                      <span>
                                        {player.name} (Seat {game.state.players.indexOf(player) + 1})
                                      </span>
                                    </label>
                                  ))}
                                </div>
                              </div>
                            )}
                            
                            <div className={disconnectedPlayers.length > 0 ? 'new-player-section divider' : 'new-player-section'}>
                              <label className="radio-option">
                                <input
                                  type="radio"
                                  name="joinOption"
                                  value="new"
                                  checked={selectedExistingPlayer === null}
                                  onChange={handleNewPlayerSelect}
                                />
                                <span>
                                  Join as new player:
                                </span>
                              </label>
                              <input
                                type="text"
                                value={playerName}
                                onChange={(e) => setPlayerName(e.target.value)}
                                placeholder="Your name"
                                disabled={selectedExistingPlayer !== null}
                                className="input"
                                required={selectedExistingPlayer === null}
                              />
                            </div>
                            
                            <div className="form-buttons">
                              <button
                                type="submit"
                                disabled={!selectedExistingPlayer && !playerName.trim()}
                                className={(!selectedExistingPlayer && !playerName.trim()) ? 'button--secondary button--small' : 'button--success button--small'}
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
                                className="button--secondary button--small"
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
                      className={game.state.state !== 'lobby' ? 'button--secondary' : 'button--success'}
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