import React, { useState, useEffect } from 'react';
import { Ctx } from 'boardgame.io';
import { GameState, PlayerState } from '../../../src/shared/types';
import { NightPrompt } from './NightPrompt';

interface NightPhaseProps {
  gameState: GameState;
  ctx: Ctx;
  moves: any;
  playerID?: string;
  currentPlayer: PlayerState | null;
}

export const NightPhase: React.FC<NightPhaseProps> = ({ 
  gameState, 
  ctx, 
  moves, 
  playerID, 
  currentPlayer 
}) => {
  const [showPrompt, setShowPrompt] = useState(false);

  // Check if current player needs to act
  useEffect(() => {
    if (currentPlayer && !currentPlayer.hasActed) {
      // Check if it's this role's turn to act
      // For now, we'll show the prompt immediately if the player has a night action
      setShowPrompt(true);
    } else {
      setShowPrompt(false);
    }
  }, [currentPlayer]);

  const canAdvanceToDay = () => {
    // Check if all players with night actions have acted
    const playersWithActions = Object.values(gameState.players).filter(player => {
      // This would check against role registry in real implementation
      return ['werewolf', 'seer', 'robber', 'troublemaker'].includes(player.role);
    });

    return playersWithActions.every(player => player.hasActed);
  };

  const handleAdvanceToDay = () => {
    if (canAdvanceToDay()) {
      moves.startDay();
    }
  };

  return (
    <div className="night-phase">
      <div className="phase-header">
        <h2>Night Phase</h2>
        <p>Roles are performing their night actions...</p>
      </div>

      <div className="night-content">
        {currentPlayer && (
          <div className="player-status">
            <h3>Your Role: {currentPlayer.role}</h3>
            <div className="action-status">
              {currentPlayer.hasActed ? (
                <span className="acted">✓ You have completed your action</span>
              ) : (
                <span className="waiting">Waiting for your action...</span>
              )}
            </div>
          </div>
        )}

        {showPrompt && currentPlayer && !currentPlayer.hasActed && (
          <NightPrompt
            role={currentPlayer.role}
            gameState={gameState}
            moves={moves}
            playerID={playerID}
          />
        )}

        <div className="player-action-status">
          <h4>Player Status</h4>
          <div className="status-list">
            {Object.values(gameState.players)
              .sort((a, b) => a.seat - b.seat)
              .map(player => (
                <div key={player.id} className="player-status-item">
                  <span>Seat {player.seat + 1}</span>
                  <span>
                    {player.hasActed ? '✓ Complete' : '⏳ Acting...'}
                  </span>
                </div>
              ))}
          </div>
        </div>

        {currentPlayer?.privateLog && currentPlayer.privateLog.length > 0 && (
          <div className="private-log">
            <h4>Your Night Log</h4>
            <div className="log-messages">
              {currentPlayer.privateLog.map((message, index) => (
                <div key={index} className="log-message">
                  {message}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="night-actions">
        {canAdvanceToDay() && (
          <button 
            className="advance-btn"
            onClick={handleAdvanceToDay}
          >
            Start Day Discussion
          </button>
        )}
      </div>
    </div>
  );
};