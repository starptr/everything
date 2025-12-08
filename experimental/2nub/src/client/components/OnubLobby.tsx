import React, { useState } from 'react';
import { GameStateClient, RoleId, ROLES, StateLobby } from '../../types';

interface OnubLobbyProps {
    stateLobby: StateLobby;
    playerCount: number;
    currentPlayerId: string;
}

export const OnubLobby: React.FC<OnubLobbyProps> = ({ stateLobby, playerCount, currentPlayerId }) => {
    console.debug("Player count: ", playerCount);

    function makeRoleAddHandler(roleId: RoleId): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            //setRoles(roles => [...roles, roleId]);
        }
    }

    function makeRoleMoveUpHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            if (index <= 0) return;
            //setRoles(roles => {
            //    const newRoles = [...roles];
            //    [newRoles[index - 1], newRoles[index]] = [newRoles[index], newRoles[index - 1]];
            //    return newRoles;
            //});
        }
    }

    function makeRoleMoveDownHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            //setRoles(roles => {
            //    if (index >= roles.length - 1) return roles;
            //    const newRoles = [...roles];
            //    [newRoles[index + 1], newRoles[index]] = [newRoles[index], newRoles[index + 1]];
            //    return newRoles;
            //});
        }
    }

    function makeRoleDeleteHandler(index: number): React.MouseEventHandler<HTMLButtonElement> {
        return (e: React.MouseEvent<HTMLButtonElement>) => {
            e.preventDefault();
            //setRoles(roles => {
            //    const newRoles = [...roles];
            //    newRoles.splice(index, 1);
            //    return newRoles;
            //});
        }
    }

    function handleSubmit(e: React.FormEvent) {
        e.preventDefault();
        throw new Error('Not implemented: handleSubmit in OnubLobby');
    }

    return <div>
        <h1>Lobby</h1>
        <p>
            Waiting for players to join...
        </p>
        <form onSubmit={handleSubmit}>
            <h2>Roles Available to be Added</h2>
            <ul>
                {ROLES.map(roleId => (
                    <li key={roleId}>
                        {roleId}{" "}
                        <button onClick={makeRoleAddHandler(roleId)}>Add</button>
                    </li>
                ))}
            </ul>
            <h2>Order of Roles</h2>
            <ol>
                {stateLobby.ruleset.roleOrder.map((roleId, index) => (
                    <li key={index}>
                        <button onClick={makeRoleMoveUpHandler(index)}>⬆️</button>
                        <button onClick={makeRoleMoveDownHandler(index)}>⬇️</button>
                        <button onClick={makeRoleDeleteHandler(index)}>❌</button>
                        {roleId}
                    </li>
                ))}
            </ol>
            <h2>Special Rules</h2>
            <label>
                <input
                    type="checkbox"
                    checked={stateLobby.ruleset.special.maybeAllTanners.enabled}
                    onChange={e => {
                        //setSpecialRuleset(ruleset => ({
                        //    ...ruleset,
                        //    maybeAllTanners: {
                        //        ...ruleset.maybeAllTanners,
                        //        enabled: e.target.checked,
                        //    },
                        //}))
                    }}
                />
                Everyone is Tanner (with probability <input
                    type="number"
                    value={stateLobby.ruleset.special.maybeAllTanners.probability}
                    min={0}
                    max={1}
                    onChange={e => {
                        const value = parseFloat(e.target.value);
                        if (isNaN(value) || !isFinite(value)) return;
                        //setSpecialRuleset(ruleset => ({
                        //    ...ruleset,
                        //    maybeAllTanners: {
                        //        ...ruleset.maybeAllTanners,
                        //        probability: parseFloat(e.target.value) || 0,
                        //    },
                        //}));
                    }}
                />)
            </label>
            <h2>Start Game</h2>
            <button type="submit" disabled={stateLobby.ruleset.roleOrder.length !== playerCount}>
                {stateLobby.ruleset.roleOrder.length === playerCount ? 'Start Game' : 'Role count and player count must match'}
            </button>
        </form>
    </div>;
}