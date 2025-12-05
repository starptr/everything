import React, { useState } from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState, DEFAULT_ROLES } from '../../server/types';

interface LobbyProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID' | 'isActive'> {}

const Lobby: React.FC<LobbyProps> = ({ G, ctx, moves, playerID }) => {
  const [playerName, setPlayerName] = useState('');
  const [selectedSeat, setSelectedSeat] = useState<number | null>(null);

  const currentPlayer = playerID ? G.players[playerID] : null;
  const isSeated = currentPlayer !== null;

  const handleSeatPlayer = () => {
    if (selectedSeat !== null && playerName && moves.seatPlayer) {
      moves.seatPlayer({ seat: selectedSeat, playerName });
      setSelectedSeat(null);
      setPlayerName('');
    }
  };

  const handleLeaveSeat = () => {
    if (moves.leaveSeat) {
      moves.leaveSeat();
    }
  };

  const handleStartGame = () => {
    if (moves.startGame) {
      moves.startGame({
        gameOptions: {
          enabledRoles: DEFAULT_ROLES,
          nightTimeLimit: 300000,
          dayTimeLimit: 300000,
          votingTimeLimit: 60000
        }
      });
    }
  };

  const occupiedSeats = new Set(Object.values(G.players).map(p => p.seat));
  const numPlayers = Object.keys(G.players).length;
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
                value={playerName}
                onChange={(e) => setPlayerName(e.target.value)}
                style={{
                  width: '100%',
                  padding: '10px',
                  border: '1px solid #ccc',
                  borderRadius: '4px',
                  fontSize: '16px'
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
              disabled={!playerName || selectedSeat === null}
              style={{
                width: '100%',
                padding: '12px',
                backgroundColor: '#28a745',
                color: 'white',
                border: 'none',
                borderRadius: '4px',
                fontSize: '16px',
                cursor: playerName && selectedSeat ? 'pointer' : 'not-allowed'
              }}
            >
              Take Seat
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
            {Object.values(G.players)
              .sort((a, b) => a.seat - b.seat)
              .map(player => (
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