import React from 'react';
import { createRoot } from 'react-dom/client';
import { Client } from 'boardgame.io/react';
import { SocketIO } from 'boardgame.io/multiplayer';
import { OneNightWerewolf } from '../../src/server/game';
import { GameBoard } from './components/GameBoard';

// Determine server URL based on environment
const SERVER_URL = process.env.NODE_ENV === 'production' 
  ? window.location.origin 
  : 'http://localhost:8000';

const WerewolfClient = Client({
  game: OneNightWerewolf,
  board: GameBoard,
  multiplayer: SocketIO({ server: `${SERVER_URL}/api` }),
  debug: process.env.NODE_ENV === 'development', // Enable debug panel in dev
});

// Simple lobby component for testing
const App: React.FC = () => {
  const [gameID, setGameID] = React.useState<string>('');
  const [playerID, setPlayerID] = React.useState<string>('');
  const [playerName, setPlayerName] = React.useState<string>('');
  const [inGame, setInGame] = React.useState<boolean>(false);

  const createGame = async () => {
    try {
      const response = await fetch(`${SERVER_URL}/api/games/OneNightWerewolf/create`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ numPlayers: 10 }),
      });
      
      const game = await response.json();
      setGameID(game.gameID);
      console.log('Created game:', game.gameID);
    } catch (error) {
      console.error('Failed to create game:', error);
    }
  };

  const joinGame = async () => {
    if (!gameID || !playerName) return;
    
    try {
      const response = await fetch(`${SERVER_URL}/api/games/OneNightWerewolf/${gameID}/join`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerName }),
      });
      
      const result = await response.json();
      setPlayerID(result.playerID);
      setInGame(true);
      console.log('Joined as player:', result.playerID);
    } catch (error) {
      console.error('Failed to join game:', error);
    }
  };

  if (inGame && gameID && playerID) {
    return <WerewolfClient gameID={gameID} playerID={playerID} />;
  }

  return (
    <div style={{ padding: '20px', maxWidth: '500px', margin: '0 auto' }}>
      <h1>One Night Ultimate Werewolf</h1>
      
      <div style={{ marginBottom: '20px' }}>
        <h3>Create New Game</h3>
        <button onClick={createGame}>Create Game</button>
      </div>

      <div style={{ marginBottom: '20px' }}>
        <h3>Join Game</h3>
        <div style={{ marginBottom: '10px' }}>
          <input
            type="text"
            placeholder="Game ID"
            value={gameID}
            onChange={(e) => setGameID(e.target.value)}
            style={{ marginRight: '10px', padding: '5px' }}
          />
        </div>
        <div style={{ marginBottom: '10px' }}>
          <input
            type="text"
            placeholder="Your Name"
            value={playerName}
            onChange={(e) => setPlayerName(e.target.value)}
            style={{ marginRight: '10px', padding: '5px' }}
          />
        </div>
        <button onClick={joinGame} disabled={!gameID || !playerName}>
          Join Game
        </button>
      </div>

      {gameID && (
        <div style={{ background: '#f0f0f0', padding: '10px', borderRadius: '5px' }}>
          <strong>Game ID:</strong> {gameID}
          <br />
          <small>Share this ID with other players</small>
        </div>
      )}
    </div>
  );
};

const appElement = document.getElementById('app');
if (appElement) {
  const root = createRoot(appElement);
  root.render(<App />);
}
