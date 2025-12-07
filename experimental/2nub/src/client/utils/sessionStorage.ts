const STORAGE_KEYS = {
  CURRENT_PLAYER_ID: 'current-player-id',
  CURRENT_GAME_ID: 'current-game-id'
} as const;

export interface SessionData {
  playerId: string | null;
  gameId: string | null;
}

export const sessionStorage = {
  setPlayerSession(playerId: string, gameId: string): void {
    window.sessionStorage.setItem(STORAGE_KEYS.CURRENT_PLAYER_ID, playerId);
    window.sessionStorage.setItem(STORAGE_KEYS.CURRENT_GAME_ID, gameId);
  },

  getPlayerSession(): SessionData {
    const playerId = window.sessionStorage.getItem(STORAGE_KEYS.CURRENT_PLAYER_ID);
    const gameId = window.sessionStorage.getItem(STORAGE_KEYS.CURRENT_GAME_ID);
    
    return { playerId, gameId };
  },

  clearPlayerSession(): void {
    window.sessionStorage.removeItem(STORAGE_KEYS.CURRENT_PLAYER_ID);
    window.sessionStorage.removeItem(STORAGE_KEYS.CURRENT_GAME_ID);
  },

  hasPlayerSession(): boolean {
    const { playerId, gameId } = this.getPlayerSession();
    return !!(playerId && gameId);
  }
};