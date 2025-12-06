import React, { useState } from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState, PlayerState } from '../../server/types';
import { getRoleDefinition } from '../../server/roles';

interface NightPhaseProps extends Pick<BoardProps<GState>, 'G' | 'ctx' | 'moves' | 'playerID' | 'isActive'> {
  currentPlayer: PlayerState | null;
}

const NightPhase: React.FC<NightPhaseProps> = ({ 
  G, 
  ctx, 
  moves, 
  playerID, 
  isActive,
  currentPlayer 
}) => {
  const [selectedTarget, setSelectedTarget] = useState<string>('');
  const [selectedTargets, setSelectedTargets] = useState<string[]>([]);
  const [selectedCenterIndices, setSelectedCenterIndices] = useState<number[]>([]);

  if (!currentPlayer) {
    return (
      <div style={{ textAlign: 'center', padding: '40px' }}>
        <h2>Night Phase</h2>
        <p>You are not in this game.</p>
      </div>
    );
  }

  const roleDefinition = getRoleDefinition(currentPlayer.originalRole);
  const nightAction = roleDefinition.nightAction;
  
  const currentNightRole = G.nightOrder[G.currentNightStep];
  const isMyTurn = currentPlayer.originalRole === currentNightRole && isActive;

  const hasAlreadyActed = G.nightActions.some(action => action.actor === playerID);

  const handleExecuteAction = () => {
    if (!moves.executeNightAction || !nightAction) return;

    const payload: any = {};

    if (nightAction.uiPrompt?.type === 'choosePlayer' && selectedTarget) {
      payload.target = selectedTarget;
    } else if (nightAction.uiPrompt?.type === 'choosePlayers' && selectedTargets.length > 0) {
      payload.targets = selectedTargets;
    }

    if (selectedCenterIndices.length > 0) {
      payload.centerIndices = selectedCenterIndices;
    }

    moves.executeNightAction(payload);
    
    setSelectedTarget('');
    setSelectedTargets([]);
    setSelectedCenterIndices([]);
  };

  const handleSkip = () => {
    if (moves.executeNightAction) {
      moves.executeNightAction({});
    }
  };

  const togglePlayerSelection = (playerId: string) => {
    if (nightAction?.uiPrompt?.type === 'choosePlayer') {
      setSelectedTarget(selectedTarget === playerId ? '' : playerId);
    } else if (nightAction?.uiPrompt?.type === 'choosePlayers') {
      setSelectedTargets(prev => 
        prev.includes(playerId) 
          ? prev.filter(id => id !== playerId)
          : [...prev, playerId]
      );
    }
  };

  const toggleCenterSelection = (index: number) => {
    setSelectedCenterIndices(prev => 
      prev.includes(index)
        ? prev.filter(i => i !== index)
        : [...prev, index]
    );
  };

  const otherPlayers = Object.values(G.players).filter(p => p.id !== playerID);

  return (
    <div style={{ maxWidth: '800px', margin: '0 auto' }}>
      <div style={{
        backgroundColor: 'white',
        padding: '30px',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
        marginBottom: '20px'
      }}>
        <h2 style={{ marginTop: 0, textAlign: 'center' }}>Night Phase</h2>
        
        <div style={{ 
          backgroundColor: '#e8f4f8', 
          padding: '20px', 
          borderRadius: '8px',
          marginBottom: '20px',
          textAlign: 'center'
        }}>
          <h3 style={{ margin: '0 0 10px 0' }}>Your Role</h3>
          <div style={{ fontSize: '24px', fontWeight: 'bold', color: '#2c5530' }}>
            {roleDefinition.name}
          </div>
          <div style={{ fontSize: '14px', color: '#666', marginTop: '5px' }}>
            {roleDefinition.description}
          </div>
        </div>

        <div style={{ marginBottom: '20px', textAlign: 'center' }}>
          <p>Current role acting: <strong>{currentNightRole || 'None'}</strong></p>
          <p>Step: {G.currentNightStep + 1} / {G.nightOrder.length}</p>
        </div>

        {currentPlayer.privateLog.length > 0 && (
          <div style={{
            backgroundColor: '#f8f9fa',
            padding: '15px',
            borderRadius: '8px',
            marginBottom: '20px'
          }}>
            <h4>Night Information</h4>
            {currentPlayer.privateLog.map((log, index) => (
              <p key={index} style={{ margin: '5px 0', fontSize: '14px' }}>
                {log}
              </p>
            ))}
          </div>
        )}

        {isMyTurn && !hasAlreadyActed && nightAction ? (
          <div>
            <h3>{nightAction.uiPrompt?.label || 'Take your action'}</h3>
            
            {(nightAction.uiPrompt?.type === 'choosePlayer' || nightAction.uiPrompt?.type === 'choosePlayers') && (
              <div style={{ marginBottom: '20px' }}>
                <h4>Select Player(s)</h4>
                <div style={{
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))',
                  gap: '10px'
                }}>
                  {otherPlayers.map(player => (
                    <button
                      key={player.id}
                      onClick={() => togglePlayerSelection(player.id)}
                      style={{
                        padding: '15px',
                        border: (selectedTarget === player.id || selectedTargets.includes(player.id)) 
                          ? '2px solid #007bff' : '1px solid #ccc',
                        borderRadius: '4px',
                        backgroundColor: (selectedTarget === player.id || selectedTargets.includes(player.id))
                          ? '#e3f2fd' : 'white',
                        cursor: 'pointer',
                        textAlign: 'left'
                      }}
                    >
                      <div style={{ fontWeight: 'bold' }}>{player.name}</div>
                      <div style={{ fontSize: '14px', color: '#666' }}>
                        Seat {player.seat}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            )}

            {nightAction.uiPrompt?.extraFields?.allowCenter && (
              <div style={{ marginBottom: '20px' }}>
                <h4>Or Select Center Cards</h4>
                <div style={{
                  display: 'flex',
                  gap: '10px',
                  justifyContent: 'center'
                }}>
                  {[0, 1, 2].map(index => (
                    <button
                      key={index}
                      onClick={() => toggleCenterSelection(index)}
                      style={{
                        padding: '20px',
                        border: selectedCenterIndices.includes(index) 
                          ? '2px solid #007bff' : '1px solid #ccc',
                        borderRadius: '4px',
                        backgroundColor: selectedCenterIndices.includes(index)
                          ? '#e3f2fd' : 'white',
                        cursor: 'pointer'
                      }}
                    >
                      Center {index + 1}
                    </button>
                  ))}
                </div>
              </div>
            )}

            <div style={{ display: 'flex', gap: '10px', justifyContent: 'center' }}>
              <button
                onClick={handleExecuteAction}
                disabled={
                  (nightAction.uiPrompt?.type === 'choosePlayer' && !selectedTarget && selectedCenterIndices.length === 0) ||
                  (nightAction.uiPrompt?.type === 'choosePlayers' && selectedTargets.length === 0)
                }
                style={{
                  padding: '12px 24px',
                  backgroundColor: '#28a745',
                  color: 'white',
                  border: 'none',
                  borderRadius: '4px',
                  fontSize: '16px',
                  cursor: 'pointer'
                }}
              >
                Confirm Action
              </button>

              {(nightAction.uiPrompt?.min === 0 || nightAction.uiPrompt?.type === 'noPrompt') && (
                <button
                  onClick={handleSkip}
                  style={{
                    padding: '12px 24px',
                    backgroundColor: '#6c757d',
                    color: 'white',
                    border: 'none',
                    borderRadius: '4px',
                    fontSize: '16px',
                    cursor: 'pointer'
                  }}
                >
                  Skip
                </button>
              )}
            </div>
          </div>
        ) : (
          <div style={{ textAlign: 'center', color: '#666' }}>
            {hasAlreadyActed ? (
              <p>You have already taken your night action. Waiting for other players...</p>
            ) : currentNightRole !== currentPlayer.originalRole ? (
              <p>Waiting for {currentNightRole} players to act...</p>
            ) : (
              <p>Waiting for your turn...</p>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

export default NightPhase;