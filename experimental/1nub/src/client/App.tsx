import React, { useState } from 'react';
import { Client } from 'boardgame.io/react';
import OneNightWerewolf from '../server/game-simple';
import Board from './components/Board';

const OneNightWerewolfClient = Client({
  game: OneNightWerewolf,
  board: Board,
  debug: process.env.NODE_ENV === 'development'
});

const App: React.FC = () => {
  const [gameID, setGameID] = useState('');
  const [playerID, setPlayerID] = useState('');
  const [playerName, setPlayerName] = useState('');
  const [gameStarted, setGameStarted] = useState(false);

  const createGame = async () => {
    const response = await fetch('http://localhost:8000/games/OneNightWerewolf/create', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        numPlayers: 8
      })
    });
    
    const { gameID } = await response.json();
    setGameID(gameID);
  };

  const joinGame = async () => {
    if (!gameID || !playerName) return;

    const response = await fetch(`http://localhost:8000/games/OneNightWerewolf/${gameID}/join`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        playerName
      })
    });
    
    const { playerCredentials } = await response.json();
    setPlayerID(playerCredentials);
    setGameStarted(true);
  };

  if (!gameStarted) {
    return (
      <div style={{ padding: '20px', maxWidth: '400px', margin: '50px auto' }}>
        <h1>One Night Ultimate Werewolf</h1>
        
        <div style={{ marginBottom: '20px' }}>
          <input
            type="text"
            placeholder="Your name"
            value={playerName}
            onChange={(e) => setPlayerName(e.target.value)}
            style={{ 
              width: '100%', 
              padding: '10px', 
              marginBottom: '10px',
              border: '1px solid #ccc',
              borderRadius: '4px'
            }}
          />
        </div>

        <div style={{ marginBottom: '20px' }}>
          <input
            type="text"
            placeholder="Game ID (leave empty to create new)"
            value={gameID}
            onChange={(e) => setGameID(e.target.value)}
            style={{ 
              width: '100%', 
              padding: '10px', 
              marginBottom: '10px',
              border: '1px solid #ccc',
              borderRadius: '4px'
            }}
          />
        </div>

        <div>
          {!gameID ? (
            <button
              onClick={createGame}
              disabled={!playerName}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: '#007bff',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: playerName ? 'pointer' : 'not-allowed'
              }}
            >
              Create Game
            </button>
          ) : (
            <button
              onClick={joinGame}
              disabled={!playerName || !gameID}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: '#28a745',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: playerName && gameID ? 'pointer' : 'not-allowed'
              }}
            >
              Join Game
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <OneNightWerewolfClient
      matchID={gameID}
      playerID={playerID}
      credentials={playerID}
    />
  );
};

export default App;