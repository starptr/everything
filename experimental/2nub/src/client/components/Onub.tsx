import React, { useState } from 'react';
import { GameStateClient } from '../../types';
import { OnubLobby } from './OnubLobby';

interface OnubProps {
	game: GameStateClient;
	currentPlayerId: string;
}

export const Onub: React.FC<OnubProps> = ({ game, currentPlayerId }) => {
	let content = <div className="game-area__placeholder">
		<p>
			This is where the actual game would be implemented. The boilerplate provides:
		</p>
		<ul>
			<li>Real-time player connection status</li>
			<li>Game state synchronization via WebSockets</li>
			<li>CRUD operations for games and players</li>
			<li>Clean separation of server and client logic</li>
		</ul>
		<div className="alert--info">
			<strong>Ready for your game logic!</strong> Add your game mechanics, rules, and UI components here.
		</div>
	</div>;

	switch (game.state.state) {
		case 'lobby':
			content = <OnubLobby stateLobby={game.state} playerCount={game.players.length} currentPlayerId={currentPlayerId} />;
		default:
		//throw new Error(`Onub component: Unsupported game state "${game.state.state}"`);
	}

	return (
		<div className="game-area">
			<h3>Game Area</h3>
			{content}
		</div>
	);
}