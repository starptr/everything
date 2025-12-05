import React, { useState } from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState, DEFAULT_ROLES } from '../../server/types';

interface LobbyProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID' | 'isActive'> {}

const Lobby: React.FC<LobbyProps> = ({ G, ctx, moves, playerID }) => {
  const [playerName, setPlayerName] = useState<string>('');
  const [selectedSeat, setSelectedSeat] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState<boolean>(false);

  // Add null checks for game state
  const safeG = G || {
    players: {},
    center: [],
    votes: {},
    nightActions: [],
    currentNightStep: 0,
    nightOrder: [],
    gameOptions: { enabledRoles: [] },
    revealed: null,
    timers: {}
  } as GState;
  
  const safeMoves = moves || {};
  const currentPlayer = playerID && safeG.players ? safeG.players[playerID] : null;
  const isSeated = currentPlayer !== null;

  const handleSeatPlayer = async () => {
    if (selectedSeat !== null && playerName.trim() && safeMoves.seatPlayer && !isLoading) {
      setIsLoading(true);
      try {
        safeMoves.seatPlayer(selectedSeat, playerName.trim());
        setSelectedSeat(null);
        setPlayerName('');
      } catch (error) {
        console.error('Error seating player:', error);
      } finally {
        setIsLoading(false);
      }
    }
  };

  const handleLeaveSeat = () => {
    if (safeMoves.leaveSeat && !isLoading) {
      safeMoves.leaveSeat();
    }
  };

  const handleStartGame = () => {
    if (safeMoves.startGame && !isLoading) {
      safeMoves.startGame({
        gameOptions: {
          enabledRoles: DEFAULT_ROLES,
          nightTimeLimit: 300000,
          dayTimeLimit: 300000,
          votingTimeLimit: 60000
        }
      });
    }
  };

  const occupiedSeats = new Set(Object.values(safeG.players || {}).map((p: any) => p?.seat).filter(seat => seat !== undefined));
  const numPlayers = Object.keys(safeG.players || {}).length;
  const canStartGame = numPlayers >= 3 && numPlayers <= 10;

  return (
    <div style={{ maxWidth: '800px', margin: '0 auto' }}>
      <div style={{
        backgroundColor: 'white',
        padding: '30px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        marginBottom: '20px'
      }}>
        <h2 style={{ marginTop: 0, textAlign: 'center' }}>Game Lobby</h2>
        
        <div style={{ marginBottom: '30px', textAlign: 'center' }}>
          <p>Players: {numPlayers}/10</p>
          <p style={{ color: '#666', fontSize: '14px' }}>
            Need 3-10 players to start the game
          </p>
        </div>

        {!isSeated ? (
          <div style={{ marginBottom: '30px' }}>
            <h3>Join the Game</h3>
            <div style={{ marginBottom: '15px' }}>
              <input
                type="text"
                placeholder="Enter your name"
                value={playerName || ''}
                onChange={(e) => setPlayerName(e.target.value)}
                disabled={isLoading}
                style={{
                  width: '100%',
                  padding: '10px',
                  border: '1px solid #ccc',
                  borderRadius: '4px',
                  fontSize: '16px',
                  opacity: isLoading ? 0.7 : 1
                }}
              />
            </div>
            <div style={{ marginBottom: '15px' }}>
              <label>Choose your seat:</label>
              <div style={{
                display: 'grid',
                gridTemplateColumns: 'repeat(5, 1fr)',
                gap: '10px',
                marginTop: '10px'
              }}>
                {Array.from({ length: 10 }, (_, i) => i + 1).map(seat => (
                  <button
                    key={seat}
                    onClick={() => setSelectedSeat(seat)}
                    disabled={occupiedSeats.has(seat)}
                    style={{
                      padding: '10px',
                      border: selectedSeat === seat ? '2px solid #007bff' : '1px solid #ccc',
                      borderRadius: '4px',
                      backgroundColor: occupiedSeats.has(seat) ? '#f8f9fa' : 
                        selectedSeat === seat ? '#e3f2fd' : 'white',
                      cursor: occupiedSeats.has(seat) ? 'not-allowed' : 'pointer',
                      color: occupiedSeats.has(seat) ? '#6c757d' : '#333'
                    }}
                  >
                    Seat {seat}
                    {occupiedSeats.has(seat) && ' (Taken)'}
                  </button>
                ))}
              </div>
            </div>
            <button
              onClick={handleSeatPlayer}
              disabled={!playerName.trim() || selectedSeat === null || isLoading}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: isLoading ? '#6c757d' : '#28a745',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: (playerName.trim() && selectedSeat !== null && !isLoading) ? 'pointer' : 'not-allowed',
                opacity: isLoading ? 0.8 : 1
              }}
            >
              {isLoading ? 'Taking Seat...' : 'Take Seat'}
            </button>
          </div>
        ) : (
          <div style={{ marginBottom: '30px' }}>
            <h3>You are seated!</h3>
            <p>
              <strong>{currentPlayer.name}</strong> - Seat {currentPlayer.seat}
            </p>
            <button
              onClick={handleLeaveSeat}
              style={{
                padding: '10px 20px',
                backgroundColor: '#dc3545',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                cursor: 'pointer'
              }}
            >
              Leave Seat
            </button>
          </div>
        )}

        <div style={{ marginBottom: '30px' }}>
          <h3>Current Players</h3>
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))',
            gap: '10px'
          }}>
            {Object.values(safeG.players || {})
              .filter((player: any) => player && player.id && player.name)
              .sort((a: any, b: any) => (a.seat || 0) - (b.seat || 0))
              .map((player: any) => (
                <div
                  key={player.id}
                  style={{
                    padding: '15px',
                    backgroundColor: '#f8f9fa',
                    borderRadius: '4px',
                    border: player.id === playerID ? '2px solid #007bff' : '1px solid #dee2e6'
                  }}
                >
                  <div style={{ fontWeight: 'bold' }}>{player.name}</div>
                  <div style={{ fontSize: '14px', color: '#666' }}>
                    Seat {player.seat}
                  </div>
                  {player.id === playerID && (
                    <div style={{ fontSize: '12px', color: '#007bff', marginTop: '5px' }}>
                      (You)
                    </div>
                  )}
                </div>
              ))}
          </div>
        </div>

        {canStartGame && (
          <div style={{ textAlign: 'center' }}>
            <button
              onClick={handleStartGame}
              style={{
                padding: '15px 30px',
                backgroundColor: '#007bff',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '18px',
                fontWeight: 'bold',
                cursor: 'pointer'
              }}
            >
              Start Game
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default Lobby;