import React, { createContext, useContext, ReactNode } from 'react';
import { StateLobby } from '../../types';

export interface SocketEventContextType {
  isConnected: boolean;
  forceDisconnectPlayer: (gameId: string, playerId: string) => Promise<void>;
  connect: () => void;
  disconnect: () => void;
  authenticatePlayer: (gameId: string, playerId: string) => void;
  updateRuleset: (ruleset: StateLobby["ruleset"]) => void;
}

const SocketEventContext = createContext<SocketEventContextType | null>(null);

interface SocketEventProviderProps {
  children: ReactNode;
  eventHandlers: SocketEventContextType;
}

export const SocketEventProvider: React.FC<SocketEventProviderProps> = ({ 
  children, 
  eventHandlers 
}) => {
  return (
    <SocketEventContext.Provider value={eventHandlers}>
      {children}
    </SocketEventContext.Provider>
  );
};

export const useSocketEventContext = (): SocketEventContextType => {
  const context = useContext(SocketEventContext);
  if (!context) {
    throw new Error('useSocketEventContext must be used within a SocketEventProvider');
  }
  return context;
};