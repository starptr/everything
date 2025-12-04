import React, { useState } from 'react';
import { PlayerState, PlayerID } from '../../../src/shared/types';

interface LobbyProps {
  players: Record<PlayerID, PlayerState>;
  moves: any;
  playerID?: string;
}

export const Lobby: React.FC<LobbyProps> = ({ players, moves, playerID }) => {
  const [selectedSeat, setSelectedSeat] = useState<number | null>(null);
  const [gameOptions, setGameOptions] = useState({
    enabledRoles: [] as string[],
    timeLimit: 300,
    autoAdvance: false,
  });

  const currentPlayer = playerID ? players[playerID] : null;
  const isSeated = currentPlayer !== undefined;
  const playerCount = Object.keys(players).length;

  const handleSeatSelect = (seat: number) => {
    if (!isSeated && !isSeatTaken(seat)) {
      moves.seatPlayer({ seat });
    }
  };

  const handleLeaveSeat = () => {
    if (isSeated) {
      moves.leaveSeat();
    }
  };

  const handleStartGame = () => {
    if (playerCount >= 3) {
      moves.startGame({ options: gameOptions });
    }
  };

  const isSeatTaken = (seat: number): boolean => {
    return Object.values(players).some(player => player.seat === seat);
  };

  const renderSeat = (seatNumber: number) => {
    const player = Object.values(players).find(p => p.seat === seatNumber);
    const isCurrentPlayer = player && player.id === playerID;
    const isTaken = player !== undefined;
    
    return (
      <div
        key={seatNumber}
        className={`seat ${isTaken ? 'taken' : 'available'} ${isCurrentPlayer ? 'current-player' : ''}`}
        onClick={() => !isTaken && handleSeatSelect(seatNumber)}
      >
        <div className="seat-number">Seat {seatNumber + 1}</div>
        {isTaken && (
          <div className="player-info">
            Player {player.id}
            {isCurrentPlayer && <span className="you-label">(You)</span>}
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="lobby">
      <div className="lobby-header">
        <h2>Game Lobby</h2>
        <p>Players: {playerCount}/10</p>
      </div>

      <div className="seating-area">
        <h3>Choose Your Seat</h3>
        <div className="seats-grid">
          {Array.from({ length: 10 }, (_, i) => renderSeat(i))}
        </div>
        
        {isSeated && (
          <button 
            className="leave-seat-btn"
            onClick={handleLeaveSeat}
          >
            Leave Seat
          </button>
        )}
      </div>

      <div className="game-setup">
        <h3>Game Options</h3>
        
        <div className="option-group">
          <label>
            Time Limit (seconds):
            <input
              type="number"
              value={gameOptions.timeLimit}
              onChange={(e) => setGameOptions(prev => ({ 
                ...prev, 
                timeLimit: parseInt(e.target.value) 
              }))}
              min={60}
              max={600}
            />
          </label>
        </div>

        <div className="option-group">
          <label>
            <input
              type="checkbox"
              checked={gameOptions.autoAdvance}
              onChange={(e) => setGameOptions(prev => ({ 
                ...prev, 
                autoAdvance: e.target.checked 
              }))}
            />
            Auto-advance phases
          </label>
        </div>

        <div className="role-selection">
          <h4>Enabled Roles</h4>
          <p>Leave empty to use default role set based on player count</p>
          {/* Role selection would go here - simplified for now */}
        </div>
      </div>

      <div className="lobby-actions">
        <button
          className="start-game-btn"
          onClick={handleStartGame}
          disabled={playerCount < 3}
        >
          Start Game {playerCount < 3 && `(Need ${3 - playerCount} more players)`}
        </button>
      </div>

      <div className="player-list">
        <h3>Current Players</h3>
        <ul>
          {Object.values(players)
            .sort((a, b) => a.seat - b.seat)
            .map(player => (
              <li key={player.id} className={player.id === playerID ? 'current-player' : ''}>
                Seat {player.seat + 1}: Player {player.id}
                {player.id === playerID && ' (You)'}
              </li>
            ))}
        </ul>
      </div>
    </div>
  );
};