import React, { useState, useEffect } from 'react';
import { PlayerState, PlayerID } from '../../../src/shared/types';

interface DayPhaseProps {
  players: Record<PlayerID, PlayerState>;
  playerID?: string;
  moves: any;
}

export const DayPhase: React.FC<DayPhaseProps> = ({ players, playerID, moves }) => {
  const [timeRemaining, setTimeRemaining] = useState(300); // 5 minutes default
  const [discussion, setDiscussion] = useState<string[]>([]);
  const [message, setMessage] = useState('');

  useEffect(() => {
    // Start countdown timer
    const timer = setInterval(() => {
      setTimeRemaining(prev => {
        if (prev <= 1) {
          clearInterval(timer);
          // Auto-advance to voting if time runs out
          moves.startVoting();
          return 0;
        }
        return prev - 1;
      });
    }, 1000);

    return () => clearInterval(timer);
  }, [moves]);

  const formatTime = (seconds: number): string => {
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;
    return `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;
  };

  const handleStartVoting = () => {
    moves.startVoting();
  };

  const handleAddMessage = () => {
    if (message.trim()) {
      // In a real implementation, this would send to other players
      setDiscussion(prev => [...prev, `Player ${playerID}: ${message}`]);
      setMessage('');
    }
  };

  const currentPlayer = playerID ? players[playerID] : null;

  return (
    <div className="day-phase">
      <div className="phase-header">
        <h2>Day Phase - Discussion Time</h2>
        <div className="timer">
          Time Remaining: {formatTime(timeRemaining)}
        </div>
      </div>

      <div className="game-info">
        <div className="player-info">
          <h3>Players in the Game</h3>
          <div className="player-list">
            {Object.values(players)
              .sort((a, b) => a.seat - b.seat)
              .map(player => (
                <div key={player.id} className={`player-card ${player.id === playerID ? 'current-player' : ''}`}>
                  <div className="player-seat">Seat {player.seat + 1}</div>
                  <div className="player-id">Player {player.id}</div>
                  {player.id === playerID && <div className="you-label">You</div>}
                </div>
              ))}
          </div>
        </div>

        {currentPlayer && (
          <div className="your-info">
            <h3>Your Information</h3>
            <div className="role-info">
              <strong>Your Role:</strong> {currentPlayer.role}
            </div>
            {currentPlayer.privateLog.length > 0 && (
              <div className="night-results">
                <strong>Night Results:</strong>
                <ul>
                  {currentPlayer.privateLog.map((log, index) => (
                    <li key={index}>{log}</li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="discussion-area">
        <h3>Discussion</h3>
        <div className="chat-messages">
          {discussion.map((msg, index) => (
            <div key={index} className="chat-message">
              {msg}
            </div>
          ))}
          {discussion.length === 0 && (
            <div className="no-messages">
              No messages yet. Start the discussion!
            </div>
          )}
        </div>

        <div className="chat-input">
          <input
            type="text"
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            onKeyPress={(e) => e.key === 'Enter' && handleAddMessage()}
            placeholder="Type your message here..."
          />
          <button onClick={handleAddMessage}>Send</button>
        </div>
      </div>

      <div className="day-instructions">
        <h4>Instructions</h4>
        <p>
          During this phase, discuss with other players to figure out who the werewolves are.
          Share information carefully - werewolves will try to blend in!
        </p>
        <ul>
          <li>Discuss what you learned during the night</li>
          <li>Try to identify suspicious behavior</li>
          <li>Work together to find the werewolves</li>
          <li>Remember: some players' roles may have changed during the night!</li>
        </ul>
      </div>

      <div className="day-actions">
        <button 
          className="start-voting-btn"
          onClick={handleStartVoting}
        >
          Start Voting Phase
        </button>
      </div>
    </div>
  );
};