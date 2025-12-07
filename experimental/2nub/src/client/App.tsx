import React, { useState, useEffect } from 'react';
import { GameBoard } from './components/GameBoard';
import { CreateGame } from './components/CreateGame';
import { GameList } from './components/GameList';
import { useWebSocket } from './hooks/useWebSocket';
import { GameState, WebSocketMessage } from '../types';

const App: React.FC = () => {
  const [games, setGames] = useState<GameState[]>([]);
  const [currentGame, setCurrentGame] = useState<GameState | null>(null);
  const [currentPlayerId, setCurrentPlayerId] = useState<string | null>(null);
  const [view, setView] = useState<'list' | 'game'>('list');

  const { isConnected, sendMessage, connect } = useWebSocket({
    onMessage: handleWebSocketMessage,
    onOpen: () => console.log('Connected to WebSocket'),
    onClose: () => console.log('Disconnected from WebSocket'),
  });

  function handleWebSocketMessage(message: WebSocketMessage) {
    switch (message.type) {
      case 'gameState':
        if (message.gameId === currentGame?.id) {
          setCurrentGame(message.data);
        }
        break;
      case 'gameCreated':
        setGames(prev => [...prev, message.data]);
        break;
      case 'gameDeleted':
        setGames(prev => prev.filter(g => g.id !== message.data.gameId));
        if (currentGame?.id === message.data.gameId) {
          setCurrentGame(null);
          setCurrentPlayerId(null);
          setView('list');
        }
        break;
      case 'playerJoined':
        if (message.gameId === currentGame?.id) {
          setCurrentGame(message.data.game);
        }
        break;
      case 'playerLeft':
        if (message.gameId === currentGame?.id) {
          setCurrentGame(message.data.game);
        }
        break;
      case 'error':
        console.error('WebSocket error:', message.data.error);
        break;
    }
  }

  const fetchGames = async () => {
    try {
      const response = await fetch('/api/games');
      console.debug('Fetch games status:', response.status);
      console.debug('Fetch games text:', await response.clone().text());
      console.debug('Fetch games response:', response);
      const result = await response.json();
      if (result.success) {
        setGames(result.data);
      }
    } catch (error) {
      console.error('Failed to fetch games:', error);
    }
  };

  const createGame = async (name: string) => {
    try {
      const response = await fetch('/api/games', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      });
      const result = await response.json();
      if (result.success) {
        console.log('Game created:', result.data);
      }
    } catch (error) {
      console.error('Failed to create game:', error);
    }
  };

  const joinGame = async (gameId: string, playerName: string) => {
    try {
      const response = await fetch(`/api/games/${gameId}/join`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerName })
      });
      const result = await response.json();
      if (result.success) {
        setCurrentGame(result.data.game);
        setCurrentPlayerId(result.data.player.id);
        setView('game');
        
        sendMessage({
          type: 'joinGame',
          data: { gameId, playerId: result.data.player.id }
        });
      }
    } catch (error) {
      console.error('Failed to join game:', error);
    }
  };

  const leaveGame = async () => {
    if (!currentGame || !currentPlayerId) return;
    
    try {
      await fetch(`/api/games/${currentGame.id}/players/${currentPlayerId}`, {
        method: 'DELETE'
      });
      setCurrentGame(null);
      setCurrentPlayerId(null);
      setView('list');
    } catch (error) {
      console.error('Failed to leave game:', error);
    }
  };

  useEffect(() => {
    connect();
    fetchGames();
  }, [connect]);

  return (
    <div style={{ padding: '20px', maxWidth: '1200px', margin: '0 auto' }}>
      <header style={{ marginBottom: '30px' }}>
        <h1 style={{ color: '#333', marginBottom: '10px' }}>2nub Game Boilerplate</h1>
        <div style={{ 
          display: 'flex', 
          alignItems: 'center', 
          gap: '15px',
          marginBottom: '20px'
        }}>
          <div style={{ 
            padding: '5px 10px', 
            borderRadius: '15px', 
            fontSize: '12px',
            backgroundColor: isConnected ? '#d4edda' : '#f8d7da',
            color: isConnected ? '#155724' : '#721c24',
            border: `1px solid ${isConnected ? '#c3e6cb' : '#f5c6cb'}`
          }}>
            {isConnected ? 'Connected' : 'Disconnected'}
          </div>
          {view === 'game' && (
            <button onClick={leaveGame} style={{
              padding: '5px 15px',
              backgroundColor: '#dc3545',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer'
            }}>
              Leave Game
            </button>
          )}
        </div>
      </header>

      {view === 'list' ? (
        <div style={{ display: 'grid', gap: '30px', gridTemplateColumns: '1fr 2fr' }}>
          <CreateGame onCreateGame={createGame} />
          <GameList games={games} onJoinGame={joinGame} onRefresh={fetchGames} />
        </div>
      ) : (
        <GameBoard 
          game={currentGame} 
          currentPlayerId={currentPlayerId}
          onLeave={leaveGame}
        />
      )}
    </div>
  );
};

export default App;