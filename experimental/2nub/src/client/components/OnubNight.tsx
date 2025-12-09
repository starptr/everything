import React, { useState } from 'react';
import { GameStateClient, Player, StateNight } from '../../types';
import '../styles/main.scss';

interface OnubNightProps {
    stateNight: StateNight;
    currentPlayerId: string;
}

export const OnubNight: React.FC<OnubNightProps> = ({ stateNight, currentPlayerId }) => {
    const { turn } = stateNight;

    const { originalRoleId } = stateNight.playerData[currentPlayerId];

    const handleEndTurn = () => {
        throw new Error('Not implemented yet');
    };

    let content = <div>Unknown state</div>;
    switch (originalRoleId) {
        case 'werewolf':
            function playerIdToName(id: Player["id"]) {
                const player = stateNight.players.find(p => p.id === id);
                return player ? player.name : 'Unknown Player';
            }
            content = <div>
                <p>The Werewolves on your team are:</p>
                <ul>
                    {Object.entries(stateNight.playerData)
                        .filter(([playerId, playerState]) => playerState.originalRoleId === 'werewolf')
                        .map(([playerId, playerState]) => <li key={playerId}>
                            {playerIdToName(playerId)} {playerId === currentPlayerId ? '(You)' : ''}
                        </li>)
                    }
                </ul>
                <button onClick={handleEndTurn}>End Turn</button>
            </div>;
            break;
        default:
            content = <div>
                <p>Your role does not have a night action.</p>
                <button onClick={handleEndTurn}>End Turn</button>
            </div>
    }

    return <div>
        <h1>Night</h1>
        {!stateNight.playerIdsByWakeupOrder[turn].includes(currentPlayerId) ? <p>
            Waiting until other players finish their turns...
        </p> : <>
            <p>
                It's your turn to wake up!
            </p>
            {content}
        </>}
    </div>;
}