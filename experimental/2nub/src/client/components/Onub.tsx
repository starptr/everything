import React, { useState } from 'react';
import { GameStateClient } from '../../types';

interface OnubProps {
    game: GameStateClient;
    currentPlayerId: string;
}

export const Onub: React.FC<OnubProps> = ({ game, currentPlayerId }) => {
    return (
        <div style={{
            backgroundColor: '#f8f9fa',
            padding: '20px',
            borderRadius: '6px',
            textAlign: 'center'
        }}>
            <h3 style={{ margin: '0 0 10px 0', color: '#333' }}>Game Area</h3>
            <p style={{ margin: '0 0 15px 0', color: '#666' }}>
                This is where the actual game would be implemented. The boilerplate provides:
            </p>
            <ul style={{ textAlign: 'left', color: '#666', margin: '0 0 20px 0', paddingLeft: '20px' }}>
                <li>Real-time player connection status</li>
                <li>Game state synchronization via WebSockets</li>
                <li>CRUD operations for games and players</li>
                <li>Clean separation of server and client logic</li>
            </ul>
            <div style={{
                padding: '15px',
                backgroundColor: '#d1ecf1',
                borderRadius: '4px',
                color: '#0c5460',
                border: '1px solid #bee5eb'
            }}>
                <strong>Ready for your game logic!</strong> Add your game mechanics, rules, and UI components here.
            </div>
        </div>
    );
}