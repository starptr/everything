import React, { useState } from 'react';
import { GameStateClient, StateNight, StateRoleAssignment } from '../../types';
import '../styles/main.scss';
import { useSocketEvents } from '../hooks/useSocketEvents';

/**
 * Remove parentheses and their contents from a string.
 * @param input String containing parentheses
 * @returns String without any parentheses and their contents
 */
function removeParenthesesNaively(input: string): string {
  return input.replace(/\s*\([^)]*\)/g, '');
}

interface OnubRoleAssignmentProps {
    stateRoleAssignment: StateRoleAssignment;
    currentPlayerId: string;
}

export const OnubRoleAssignment: React.FC<OnubRoleAssignmentProps> = ({ stateRoleAssignment, currentPlayerId }) => {
    const { confirmRoleAssignment } = useSocketEvents();
    const roleWithParentheses = stateRoleAssignment.playerData[currentPlayerId].originalRoleId;
    const role = removeParenthesesNaively(roleWithParentheses);
    return <div>
        <h1>Role Assignment</h1>
        <p>Your role is: <b>{role}</b></p>
        <button onClick={confirmRoleAssignment}>Confirm</button>
    </div>;
}