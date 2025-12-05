import React, { useState } from 'react';
import { Client } from 'boardgame.io/react';
import OneNightWerewolf from '../server/game-simple';
import Board from './components/Board';
import ErrorBoundary from './components/ErrorBoundary';

const OneNightWerewolfClient = Client({
  game: OneNightWerewolf,
  board: Board,
  debug: process.env.NODE_ENV === 'development'
});

const App: React.FC = () => {
  const [gameID, setGameID] = useState<string>('');
  const [playerID, setPlayerID] = useState<string>('');
  const [playerName, setPlayerName] = useState<string>('');
  const [gameStarted, setGameStarted] = useState<boolean>(false);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string>('');

  const createGame = async () => {
    if (!playerName.trim()) {
      setError('Please enter your name');
      return;
    }

    setLoading(true);
    setError('');

    try {
      const response = await fetch('http://localhost:8000/games/OneNightWerewolf/create', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          numPlayers: 8
        })
      });
      
      if (!response.ok) {
        throw new Error(`Failed to create game: ${response.statusText}`);
      }

      const data = await response.json();
      const newGameID = data.gameID || data.matchID || '';
      
      if (!newGameID) {
        throw new Error('Invalid game ID received from server');
      }

      setGameID(newGameID);
    } catch (err) {
      console.error('Error creating game:', err);
      setError(err instanceof Error ? err.message : 'Failed to create game');
    } finally {
      setLoading(false);
    }
  };

  const joinGame = async () => {
    if (!gameID.trim() || !playerName.trim()) {
      setError('Please enter both your name and game ID');
      return;
    }

    setLoading(true);
    setError('');

    try {
      const response = await fetch(`http://localhost:8000/games/OneNightWerewolf/${gameID}/join`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          playerName: playerName.trim()
        })
      });
      
      if (!response.ok) {
        throw new Error(`Failed to join game: ${response.statusText}`);
      }

      const data = await response.json();
      const credentials = data.playerCredentials || data.playerID || '';
      
      if (!credentials) {
        throw new Error('Invalid player credentials received from server');
      }

      setPlayerID(credentials);
      setGameStarted(true);
    } catch (err) {
      console.error('Error joining game:', err);
      setError(err instanceof Error ? err.message : 'Failed to join game');
    } finally {
      setLoading(false);
    }
  };

  if (!gameStarted) {
    return (
      <div style={{ padding: '20px', maxWidth: '400px', margin: '50px auto' }}>
        <h1>One Night Ultimate Werewolf</h1>
        
        {error && (
          <div style={{
            backgroundColor: '#f8d7da',
            color: '#721c24',
            padding: '12px',
            borderRadius: '4px',
            marginBottom: '20px',
            border: '1px solid #f5c6cb'
          }}>
            {error}
          </div>
        )}

        <div style={{ marginBottom: '20px' }}>
          <input
            type="text"
            placeholder="Your name"
            value={playerName || ''}
            onChange={(e) => setPlayerName(e.target.value)}
            disabled={loading}
            style={{ 
              width: '100%', 
              padding: '10px', 
              marginBottom: '10px',
              border: '1px solid #ccc',
              borderRadius: '4px',
              opacity: loading ? 0.7 : 1
            }}
          />
        </div>

        <div style={{ marginBottom: '20px' }}>
          <input
            type="text"
            placeholder="Game ID (leave empty to create new)"
            value={gameID || ''}
            onChange={(e) => setGameID(e.target.value)}
            disabled={loading}
            style={{ 
              width: '100%', 
              padding: '10px', 
              marginBottom: '10px',
              border: '1px solid #ccc',
              borderRadius: '4px',
              opacity: loading ? 0.7 : 1
            }}
          />
        </div>

        <div>
          {!gameID ? (
            <button
              onClick={createGame}
              disabled={!playerName.trim() || loading}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: loading ? '#6c757d' : '#007bff',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: (!playerName.trim() || loading) ? 'not-allowed' : 'pointer',
                opacity: loading ? 0.8 : 1
              }}
            >
              {loading ? 'Creating Game...' : 'Create Game'}
            </button>
          ) : (
            <button
              onClick={joinGame}
              disabled={!playerName.trim() || !gameID.trim() || loading}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: loading ? '#6c757d' : '#28a745',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: (!playerName.trim() || !gameID.trim() || loading) ? 'not-allowed' : 'pointer',
                opacity: loading ? 0.8 : 1
              }}
            >
              {loading ? 'Joining Game...' : 'Join Game'}
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <ErrorBoundary>
      <OneNightWerewolfClient
        matchID={gameID}
        playerID={playerID}
        credentials={playerID}
      />
    </ErrorBoundary>
  );
};

export default App;