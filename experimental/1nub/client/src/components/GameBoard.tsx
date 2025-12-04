import React from 'react';
import { BoardProps } from 'boardgame.io/react';
import { GameState, GAME_PHASES } from '../../../src/shared/types';
import { Lobby } from './Lobby';
import { NightPhase } from './NightPhase';
import { DayPhase } from './DayPhase';
import { VotingPhase } from './VotingPhase';
import { RevealPhase } from './RevealPhase';

interface GameBoardProps extends BoardProps<GameState> {}

export const GameBoard: React.FC<GameBoardProps> = ({ G, ctx, moves, playerID }) => {
  const currentPlayer = playerID ? G.players[playerID] : null;

  // Render different components based on game phase
  const renderPhase = () => {
    switch (ctx.phase) {
      case GAME_PHASES.lobby:
        return (
          <Lobby
            players={G.players}
            moves={moves}
            playerID={playerID}
          />
        );

      case GAME_PHASES.night:
        return (
          <NightPhase
            gameState={G}
            ctx={ctx}
            moves={moves}
            playerID={playerID}
            currentPlayer={currentPlayer}
          />
        );

      case GAME_PHASES.day:
        return (
          <DayPhase
            players={G.players}
            playerID={playerID}
            moves={moves}
          />
        );

      case GAME_PHASES.voting:
        return (
          <VotingPhase
            players={G.players}
            votes={G.votes}
            moves={moves}
            playerID={playerID}
          />
        );

      case GAME_PHASES.reveal:
        return (
          <RevealPhase
            gameState={G}
            moves={moves}
          />
        );

      default:
        return <div>Unknown game phase: {ctx.phase}</div>;
    }
  };

  return (
    <div className="game-board">
      <header className="game-header">
        <h1>One Night Ultimate Werewolf</h1>
        <div className="game-info">
          <span>Phase: {ctx.phase}</span>
          {playerID && <span>You are Player {playerID}</span>}
          {currentPlayer && currentPlayer.role && (
            <span>Role: {currentPlayer.role}</span>
          )}
        </div>
      </header>

      <main className="game-content">
        {renderPhase()}
      </main>

      {/* Debug info for development */}
      {process.env.NODE_ENV === 'development' && (
        <details className="debug-info">
          <summary>Debug Info</summary>
          <pre>{JSON.stringify({ G, ctx }, null, 2)}</pre>
        </details>
      )}
    </div>
  );
};