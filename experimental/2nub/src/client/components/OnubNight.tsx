import React, { useState } from 'react';
import { GameStateClient, StateNight } from '../../types';
import '../styles/main.scss';

interface OnubNightProps {
    stateNight: StateNight;
    currentPlayerId: string;
}

export const OnubNight: React.FC<OnubNightProps> = ({ stateNight, currentPlayerId }) => {
    const { turn } = stateNight;

    return <div>
        <h1>Night</h1>
        {!stateNight.playerIdsByWakeupOrder[turn].includes(currentPlayerId) ? <p>
            Waiting until other players finish their turns...
        </p> : <>
            <p>
                It's your turn to wake up!
            </p>
        </>}
    </div>;
}