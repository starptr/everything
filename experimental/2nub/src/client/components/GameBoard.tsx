import React, { useState } from 'react';
import { GameStateClient } from '../../types';
import { Onub } from './Onub';
import '../styles/main.scss';

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
        <div className="loading-state">
          <h2>Loading game...</h2>
          <p>Connecting to game and loading data...</p>
          <div className="loading-spinner" />
          <button onClick={onLeave} className="button--secondary">
            Cancel
          </button>
        </div>
      );
    }
    
    // No gameId means the game doesn't exist
    return (
      <div className="not-found">
        <h2>Game not found</h2>
        <p>The game you were in no longer exists.</p>
        <button onClick={onLeave} className="button--primary">
          Back to Game List
        </button>
      </div>
    );
  }
  console.debug("Game:", game);

  const currentPlayer = currentPlayerId ? game.state.players.find(p => p.id === currentPlayerId) : null;
  const playerList = game.state.players;
  const isCurrentPlayerDisconnected = currentPlayer && !currentPlayer.connected;

  return (
    <div className="game-board">
      <div className="header">
        <div>
          <h1>{game.name}</h1>
          <div className="game-meta">
            <span>Game ID: <strong>{gameId}</strong></span>
            <span>Players: <strong>{game.state.players.length}</strong></span>
            <span className={`status-badge ${game.state.state === 'lobby' ? 'waiting' : 'in-progress'}`}>
              {game.state.state === 'lobby' ? 'Waiting' : game.state.state}
            </span>
          </div>
        </div>
      </div>

      {isCurrentPlayerDisconnected && (
        <div className="alert alert--danger">
          <div className="alert-content">
            <div className="status-indicator disconnected" />
            <div className="alert-text">
              <strong>You are currently disconnected</strong>
              <p>
                Trying to reconnect... You can refresh the page or use the rejoin feature if needed.
              </p>
            </div>
          </div>
        </div>
      )}

      {currentPlayer && (
        <div className="current-player">
          <h3>You are:</h3>
          <p>
            <strong>{currentPlayer.name}</strong> (Seat {game.state.players.indexOf(currentPlayer) + 1})
          </p>
        </div>
      )}

      <div className="players-section">
        <h3>Players in Game:</h3>
        {playerList.length === 0 ? (
          <p className="empty-state">No players in the game yet.</p>
        ) : (
          <div className="players-grid">
            {playerList.map((player) => (
              <div key={player.id} className={`player-card ${player.id === currentPlayerId ? 'current' : ''}`}>
                <div className="player-info">
                  <div className="player-name">
                    {player.name} {player.id === currentPlayerId && '(You)'}
                  </div>
                  <div className="player-seat">
                    Seat {game.state.players.indexOf(player) + 1}
                  </div>
                </div>
                <div className="player-actions">
                  {player.connected && player.id !== currentPlayerId && (
                    <button
                      onClick={() => handleForceDisconnect(player.id, player.name)}
                      disabled={disconnectingPlayerId === player.id}
                      className="disconnect-btn"
                      title="Force disconnect this player"
                    >
                      {disconnectingPlayerId === player.id ? '...' : 'Disconnect'}
                    </button>
                  )}
                  <div 
                    title={player.connected ? 'Connected' : 'Disconnected'}
                    className={`status-indicator ${player.connected ? 'connected' : 'disconnected'}`}
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