import React, { useState, useEffect, useCallback } from 'react';
import { GameBoard } from './components/GameBoard';
import { CreateGame } from './components/CreateGame';
import { GameList } from './components/GameList';
import { useGameEvents } from './hooks/useGameEvents';
import { GameState, GameStateClient, WebSocketMessage, StateLobby } from '../types';
import { buildApiUrl } from './config/api';
import { sessionStorage } from './utils/sessionStorage';

const App: React.FC = () => {
  const [games, setGames] = useState<GameState[]>([]);
  const [currentGame, setCurrentGame] = useState<GameStateClient | null>(null);
  const [currentGameId, setCurrentGameId] = useState<string | null>(null);
  const [currentPlayerId, setCurrentPlayerId] = useState<string | null>(null);
  const [view, setView] = useState<'list' | 'game'>('list');

  const fetchGames = useCallback(async () => {
    try {
      const response = await fetch(buildApiUrl('api/games'));
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
  }, []);

  const onGameState = useCallback((gameState: GameStateClient) => {
    // Always update game state when received - ID matching is handled by socket.io room membership
    setCurrentGame(gameState);
  }, []);

  const onGameCreated = useCallback((game: GameState) => {
    setGames(prevGames => [game, ...prevGames]);
  }, []);

  const onGameDeleted = useCallback((data: { gameId: string }) => {
    setGames(prevGames => prevGames.filter(game => game.id !== data.gameId));
    
    // If the current game was deleted, return to list view
    if (currentGameId === data.gameId) {
      setCurrentGame(null);
      setCurrentGameId(null);
      setCurrentPlayerId(null);
      setView('list');
      sessionStorage.clearPlayerSession();
    }
  }, [currentGameId]);

  const onPlayerJoined = useCallback(() => {
    // Refresh games list to show updated player counts
    fetchGames();
  }, [fetchGames]);

  const onPlayerLeft = useCallback(() => {
    // Refresh games list to show updated player counts  
    fetchGames();
  }, [fetchGames]);

  const onServerError = useCallback((data: { error: string }) => {
    console.error('Server error:', data.error);
    // Could show a toast notification or error banner here
  }, []);

  const onDisconnect = useCallback(() => {
    console.log('Disconnected from Socket.io');
    
    // Immediately update current player's connection status in local state
    if (currentGame && currentPlayerId) {
      setCurrentGame(prevGame => {
        if (!prevGame) return prevGame;
        
        return {
          ...prevGame,
          players: prevGame.players.map(player =>
            player.id === currentPlayerId
              ? { ...player, connected: false }
              : player
          )
        };
      });
    }
  }, [currentGame, currentPlayerId]);

  const { isConnected, forceDisconnectPlayer, connect, authenticatePlayer, updateRuleset } = useGameEvents({
    onGameState,
    onGameCreated,
    onGameDeleted,
    onPlayerJoined,
    onPlayerLeft,
    onServerError,
    onConnect: () => {
      console.log('Connected to Socket.io');
    },
    onDisconnect,
    onConnectionError: (error) => console.error('Socket.io connection error:', error),
    gameId: currentGameId || undefined,
    playerId: currentPlayerId || undefined
  });

  const createGame = async (name: string) => {
    try {
      const response = await fetch(buildApiUrl('api/games'), {
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

  const attemptRejoin = async (gameId: string, playerId: string): Promise<boolean> => {
    try {
      const response = await fetch(buildApiUrl(`api/games/${gameId}/rejoin`), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerId })
      });
      console.debug('HTTP rejoin response:', response.clone());
      const result = await response.json();
      console.debug('Response json:', result);
      if (result.success) {
        // Game state will be received via socket.io after authentication
        setCurrentGameId(gameId);
        setCurrentPlayerId(result.data.player.id);
        setView('game');
        // Authentication and game state update will happen automatically via socket.io
        
        return true;
      }
    } catch (error) {
      console.error('Failed to rejoin game:', error);
    }
    return false;
  };

  const joinGame = async (gameId: string, playerName: string) => {
    try {
      const response = await fetch(buildApiUrl(`api/games/${gameId}/join`), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerName })
      });
      const result = await response.json();
      if (result.success) {
        // Game state will be received via socket.io after authentication
        setCurrentGameId(gameId);
        setCurrentPlayerId(result.data.player.id);
        setView('game');
        
        sessionStorage.setPlayerSession(result.data.player.id, gameId);
        // Authentication and game state update will happen automatically via socket.io
      } else {
        console.error('Failed to join game:', result.error);
      }
    } catch (error) {
      console.error('Failed to join game:', error);
    }
  };

  const leaveGame = async () => {
    console.debug('Leaving game:', currentGameId, currentPlayerId);
    if (!currentGameId || !currentPlayerId) return;
    
    try {
      await fetch(buildApiUrl(`api/games/${currentGameId}/players/${currentPlayerId}`), {
        method: 'DELETE'
      });
      setCurrentGame(null);
      setCurrentGameId(null);
      setCurrentPlayerId(null);
      setView('list');
      sessionStorage.clearPlayerSession();
    } catch (error) {
      console.error('Failed to leave game:', error);
    }
  };

  const handleForceDisconnect = async (playerId: string) => {
    if (!currentGame) return;
    
    try {
      // Use REST API to force disconnect
      await forceDisconnectPlayer(currentGameId!, playerId);
    } catch (error) {
      console.error('Failed to force disconnect player:', error);
    }
  };

  useEffect(() => {
    const initializeApp = async () => {
      connect();
      await fetchGames();
      
      const session = sessionStorage.getPlayerSession();
      console.debug('Retrieved session from storage:', session);
      if (session.playerId && session.gameId) {
        const rejoined = await attemptRejoin(session.gameId, session.playerId);
        if (!rejoined) {
          console.debug('Failed to rejoin session, clearing stored session');
          sessionStorage.clearPlayerSession();
        }
      }
    };
    
    initializeApp();
  }, []);

  // Authentication is now handled automatically in useWebSocket hook

  return (
    <div style={{ padding: '20px', maxWidth: '1200px', margin: '0 auto' }}>
      <header style={{ marginBottom: '30px' }}>
        <h1 style={{ color: '#333', marginBottom: '10px' }}>2nub Game Boilerplate</h1>
        <div style={{ 
          display: 'flex', 
          alignItems: 'center', 
          gap: '15px', 
          marginBottom: '10px' 
        }}>
          <div style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            padding: '4px 8px',
            borderRadius: '4px',
            backgroundColor: isConnected ? '#d4edda' : '#f8d7da',
            color: isConnected ? '#155724' : '#721c24',
            border: isConnected ? '1px solid #c3e6cb' : '1px solid #f5c6cb',
            fontSize: '12px'
          }}>
            <div style={{
              width: '8px',
              height: '8px',
              borderRadius: '50%',
              backgroundColor: isConnected ? '#28a745' : '#dc3545'
            }} />
            {isConnected ? 'Connected' : 'Disconnected'}
          </div>
          {!isConnected && (
            <button
              onClick={connect}
              style={{
                padding: '4px 8px',
                fontSize: '12px',
                backgroundColor: '#007bff',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                cursor: 'pointer'
              }}
            >
              Reconnect
            </button>
          )}
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
          <GameList games={games} onJoinGame={joinGame} onRejoinGame={attemptRejoin} onRefresh={fetchGames} />
        </div>
      ) : (
        <GameBoard 
          game={currentGame} 
          gameId={currentGameId}
          currentPlayerId={currentPlayerId}
          onLeave={leaveGame}
          onForceDisconnect={handleForceDisconnect}
          updateRuleset={updateRuleset}
        />
      )}
    </div>
  );
};

export default App;