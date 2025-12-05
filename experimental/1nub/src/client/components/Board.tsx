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
  const currentPlayer = playerID ? G.players[playerID] : null;

  const renderPhase = () => {
    switch (ctx.phase) {
      case 'lobby':
        return (
          <Lobby
            G={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
            isActive={isActive}
          />
        );
      case 'night':
        return (
          <NightPhase
            G={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
            isActive={isActive}
            currentPlayer={currentPlayer}
          />
        );
      case 'day':
        return (
          <DayPhase
            G={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
            currentPlayer={currentPlayer}
          />
        );
      case 'voting':
        return (
          <VotingPhase
            G={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
            currentPlayer={currentPlayer}
          />
        );
      case 'reveal':
        return (
          <RevealPhase
            G={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
          />
        );
      default:
        return <div>Unknown phase: {ctx.phase}</div>;
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
          <span>Phase: <strong>{ctx.phase}</strong></span>
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