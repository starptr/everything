import React from 'react';
import { GameStateClient, RoleId, ROLES, StateLobby } from '../../types';
import { useSocketEvents } from '../hooks/useSocketEvents';
import '../styles/main.scss';

interface OnubLobbyProps {
    stateLobby: StateLobby;
    playerCount: number;
    currentPlayerId: string;
}

export const OnubLobby: React.FC<OnubLobbyProps> = ({ stateLobby, playerCount, currentPlayerId }) => {
    const { updateRuleset } = useSocketEvents();
    console.debug("Player count: ", playerCount);

    function makeRoleAddHandler(roleId: RoleId): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            const newRuleset = {
                ...stateLobby.ruleset,
                roleOrder: [...stateLobby.ruleset.roleOrder, roleId]
            };
            updateRuleset(newRuleset);
        }
    }

    function makeRoleMoveUpHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            if (index <= 0) return;
            const newRoleOrder = [...stateLobby.ruleset.roleOrder];
            [newRoleOrder[index - 1], newRoleOrder[index]] = [newRoleOrder[index], newRoleOrder[index - 1]];
            const newRuleset = {
                ...stateLobby.ruleset,
                roleOrder: newRoleOrder
            };
            updateRuleset(newRuleset);
        }
    }

    function makeRoleMoveDownHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            if (index >= stateLobby.ruleset.roleOrder.length - 1) return;
            const newRoleOrder = [...stateLobby.ruleset.roleOrder];
            [newRoleOrder[index + 1], newRoleOrder[index]] = [newRoleOrder[index], newRoleOrder[index + 1]];
            const newRuleset = {
                ...stateLobby.ruleset,
                roleOrder: newRoleOrder
            };
            updateRuleset(newRuleset);
        }
    }

    function makeRoleDeleteHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            const newRoleOrder = [...stateLobby.ruleset.roleOrder];
            newRoleOrder.splice(index, 1);
            const newRuleset = {
                ...stateLobby.ruleset,
                roleOrder: newRoleOrder
            };
            updateRuleset(newRuleset);
        }
    }

    function handleSubmit(e: React.FormEvent) {
        e.preventDefault();
        throw new Error('Not implemented: handleSubmit in OnubLobby');
    }

    return (
        <div className="lobby">
            <h1>Lobby</h1>
            <p>Waiting for players to join...</p>
            <form onSubmit={handleSubmit} className="form">
                <div className="roles-section">
                    <h2>Roles Available to be Added</h2>
                    <ul className="roles-list">
                        {ROLES.map(roleId => (
                            <li key={roleId}>
                                {roleId}{" "}
                                <button onClick={makeRoleAddHandler(roleId)}>Add</button>
                            </li>
                        ))}
                    </ul>
                </div>
                
                <div className="role-order">
                    <h2>Order of Roles</h2>
                    <ol className="role-list">
                        {stateLobby.ruleset.roleOrder.map((roleId, index) => (
                            <li key={index} className="role-item">
                                <button onClick={makeRoleMoveUpHandler(index)}>⬆️</button>
                                <button onClick={makeRoleMoveDownHandler(index)}>⬇️</button>
                                <button onClick={makeRoleDeleteHandler(index)}>❌</button>
                                {roleId}
                            </li>
                        ))}
                    </ol>
                </div>
                
                <div className="special-rules">
                    <h2>Special Rules</h2>
                    <label className="rule-option">
                        <input
                            type="checkbox"
                            checked={stateLobby.ruleset.special.maybeAllTanners.enabled}
                            onChange={e => {
                                const newRuleset = {
                                    ...stateLobby.ruleset,
                                    special: {
                                        ...stateLobby.ruleset.special,
                                        maybeAllTanners: {
                                            ...stateLobby.ruleset.special.maybeAllTanners,
                                            enabled: e.target.checked,
                                        },
                                    }
                                };
                                updateRuleset(newRuleset);
                            }}
                        />
                        Everyone is Tanner (with probability
                        <input
                            type="number"
                            value={stateLobby.ruleset.special.maybeAllTanners.probability}
                            min={0}
                            max={1}
                            step={0.01}
                            onChange={e => {
                                const value = parseFloat(e.target.value);
                                if (isNaN(value) || !isFinite(value)) return;
                                const newRuleset = {
                                    ...stateLobby.ruleset,
                                    special: {
                                        ...stateLobby.ruleset.special,
                                        maybeAllTanners: {
                                            ...stateLobby.ruleset.special.maybeAllTanners,
                                            probability: value,
                                        },
                                    }
                                };
                                updateRuleset(newRuleset);
                            }}
                            className="input"
                        />)
                    </label>
                </div>
                
                <div className="start-section">
                    <h2>Start Game</h2>
                    <button 
                        type="submit" 
                        disabled={stateLobby.ruleset.roleOrder.length !== playerCount}
                        className="button--primary button--large"
                    >
                        {stateLobby.ruleset.roleOrder.length === playerCount ? 'Start Game' : 'Role count and player count must match'}
                    </button>
                </div>
            </form>
        </div>
    );
}