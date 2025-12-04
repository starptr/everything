import React, { useState } from 'react';
import { GameState } from '../../../src/shared/types';

interface NightPromptProps {
  role: string;
  gameState: GameState;
  moves: any;
  playerID?: string;
}

export const NightPrompt: React.FC<NightPromptProps> = ({ role, gameState, moves, playerID }) => {
  const [selectedTarget, setSelectedTarget] = useState<string>('');
  const [selectedTargets, setSelectedTargets] = useState<string[]>([]);
  const [selectedCenterCard, setSelectedCenterCard] = useState<number | null>(null);

  const otherPlayers = Object.values(gameState.players).filter(p => p.id !== playerID);

  const handleExecuteAction = () => {
    const payload: any = {};

    switch (role) {
      case 'seer':
        if (selectedTarget) {
          payload.target = selectedTarget;
        } else if (selectedCenterCard !== null) {
          payload.centerCard = selectedCenterCard;
        }
        break;

      case 'robber':
        if (selectedTarget) {
          payload.target = selectedTarget;
        }
        break;

      case 'troublemaker':
        if (selectedTargets.length === 2) {
          payload.target = selectedTargets;
        }
        break;

      case 'werewolf':
        // Werewolf action is automatic
        break;

      default:
        break;
    }

    moves.executeNightAction(payload);
  };

  const handlePass = () => {
    moves.passNightAction();
  };

  const canExecute = () => {
    switch (role) {
      case 'seer':
        return selectedTarget || selectedCenterCard !== null;
      case 'robber':
        return true; // Can always pass
      case 'troublemaker':
        return selectedTargets.length === 2 || selectedTargets.length === 0; // Can pass
      case 'werewolf':
        return true; // Automatic action
      default:
        return false;
    }
  };

  const renderRolePrompt = () => {
    switch (role) {
      case 'werewolf':
        return (
          <div className="role-prompt">
            <h3>Werewolf Action</h3>
            <p>Looking for other werewolves...</p>
            <button onClick={handleExecuteAction} className="action-btn">
              Continue
            </button>
          </div>
        );

      case 'seer':
        return (
          <div className="role-prompt">
            <h3>Seer Action</h3>
            <p>Choose a player to look at their card, or look at two center cards:</p>
            
            <div className="choice-section">
              <h4>Look at a Player's Card</h4>
              <div className="player-targets">
                {otherPlayers.map(player => (
                  <button
                    key={player.id}
                    className={`target-btn ${selectedTarget === player.id ? 'selected' : ''}`}
                    onClick={() => {
                      setSelectedTarget(selectedTarget === player.id ? '' : player.id);
                      setSelectedCenterCard(null);
                    }}
                  >
                    Seat {player.seat + 1}
                  </button>
                ))}
              </div>
            </div>

            <div className="choice-section">
              <h4>Or Look at Center Cards</h4>
              <button
                className={`center-btn ${selectedCenterCard === 0 ? 'selected' : ''}`}
                onClick={() => {
                  setSelectedCenterCard(selectedCenterCard === 0 ? null : 0);
                  setSelectedTarget('');
                }}
              >
                Look at 2 Center Cards
              </button>
            </div>

            <div className="action-buttons">
              <button 
                onClick={handleExecuteAction} 
                disabled={!canExecute()}
                className="action-btn"
              >
                Execute Action
              </button>
            </div>
          </div>
        );

      case 'robber':
        return (
          <div className="role-prompt">
            <h3>Robber Action</h3>
            <p>Choose a player to rob (swap roles with), or pass:</p>
            
            <div className="player-targets">
              {otherPlayers.map(player => (
                <button
                  key={player.id}
                  className={`target-btn ${selectedTarget === player.id ? 'selected' : ''}`}
                  onClick={() => {
                    setSelectedTarget(selectedTarget === player.id ? '' : player.id);
                  }}
                >
                  Rob Seat {player.seat + 1}
                </button>
              ))}
            </div>

            <div className="action-buttons">
              <button onClick={handlePass} className="pass-btn">
                Don't Rob Anyone
              </button>
              <button 
                onClick={handleExecuteAction} 
                disabled={!selectedTarget}
                className="action-btn"
              >
                Rob Player
              </button>
            </div>
          </div>
        );

      case 'troublemaker':
        return (
          <div className="role-prompt">
            <h3>Troublemaker Action</h3>
            <p>Choose two players to swap their cards, or pass:</p>
            
            <div className="player-targets">
              {otherPlayers.map(player => (
                <button
                  key={player.id}
                  className={`target-btn ${selectedTargets.includes(player.id) ? 'selected' : ''}`}
                  onClick={() => {
                    if (selectedTargets.includes(player.id)) {
                      setSelectedTargets(prev => prev.filter(id => id !== player.id));
                    } else if (selectedTargets.length < 2) {
                      setSelectedTargets(prev => [...prev, player.id]);
                    }
                  }}
                  disabled={!selectedTargets.includes(player.id) && selectedTargets.length >= 2}
                >
                  Seat {player.seat + 1}
                </button>
              ))}
            </div>

            <p>Selected: {selectedTargets.length}/2 players</p>

            <div className="action-buttons">
              <button onClick={handlePass} className="pass-btn">
                Don't Swap Anyone
              </button>
              <button 
                onClick={handleExecuteAction} 
                disabled={selectedTargets.length !== 2}
                className="action-btn"
              >
                Swap Players
              </button>
            </div>
          </div>
        );

      default:
        return (
          <div className="role-prompt">
            <h3>{role} Action</h3>
            <p>You have no night action.</p>
            <button onClick={handlePass} className="action-btn">
              Continue
            </button>
          </div>
        );
    }
  };

  return (
    <div className="night-prompt">
      {renderRolePrompt()}
    </div>
  );
};