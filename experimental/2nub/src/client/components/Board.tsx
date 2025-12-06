import React from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GState } from '../../server/types';
import Lobby from './Lobby';
import NightPhase from './NightPhase';
import DayPhase from './DayPhase';
import VotingPhase from './VotingPhase';
import RevealPhase from './RevealPhase';

interface GameBoardProps extends BoardProps<GState> {}

const Board: React.FC<GameBoardProps> = ({ G, ctx, moves, playerID, isActive }) => {
  // Add defensive checks for game state - only apply defensive fallbacks if G or ctx is null/undefined
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
  
  const safeCtx = ctx || {
    phase: 'lobby',
    numPlayers: 0,
    playOrder: [],
    playOrderPos: 0,
    activePlayers: null,
    currentPlayer: null,
    turn: 0,
    gameover: undefined
  } as any;
  
  const safeMoves = moves || {};
  
  const currentPlayer = playerID && safeG.players ? safeG.players[playerID] : null;

  const renderPhase = () => {
    switch (safeCtx.phase) {
      case 'lobby':
        return (
          <Lobby
            G={safeG}
            ctx={safeCtx}
            moves={safeMoves}
            playerID={playerID}
            isActive={isActive}
          />
        );
      case 'night':
        return (
          <NightPhase
            G={safeG}
            ctx={safeCtx}
            moves={safeMoves}
            playerID={playerID}
            isActive={isActive}
            currentPlayer={currentPlayer}
          />
        );
      case 'day':
        return (
          <DayPhase
            G={safeG}
            ctx={safeCtx}
            moves={safeMoves}
            playerID={playerID}
            currentPlayer={currentPlayer}
          />
        );
      case 'voting':
        return (
          <VotingPhase
            G={safeG}
            ctx={safeCtx}
            moves={safeMoves}
            playerID={playerID}
            currentPlayer={currentPlayer}
          />
        );
      case 'reveal':
        return (
          <RevealPhase
            G={safeG}
            ctx={safeCtx}
            moves={safeMoves}
            playerID={playerID}
          />
        );
      default:
        return <div>Unknown phase: {safeCtx.phase}</div>;
    }
  };

  return (
    <div style={{ 
      minHeight: '100vh', 
      padding: '20px',
      backgroundColor: '#f5f5f5'
    }}>
      <header style={{ 
        textAlign: 'center', 
        marginBottom: '30px',
        padding: '20px',
        backgroundColor: 'white',
        borderRadius: '8px',
        boxShadow: '0 2px 4px rgba(0,0,0,0.1)'
      }}>
        <h1 style={{ 
          margin: '0 0 10px 0',
          color: '#333',
          fontSize: '2rem'
        }}>
          One Night Ultimate Werewolf
        </h1>
        <div style={{
          display: 'flex',
          justifyContent: 'center',
          gap: '20px',
          fontSize: '14px',
          color: '#666'
        }}>
          <span>Phase: <strong>{safeCtx.phase || 'loading'}</strong></span>
          {currentPlayer && (
            <span>You are: <strong>{currentPlayer.name}</strong></span>
          )}
        </div>
      </header>

      <main>
        {renderPhase()}
      </main>
    </div>
  );
};

export default Board;