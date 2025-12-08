import React, { useState } from 'react';
import '../styles/main.scss';

interface CreateGameProps {
  onCreateGame: (name: string) => void;
}

export const CreateGame: React.FC<CreateGameProps> = ({ onCreateGame }) => {
  const [gameName, setGameName] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (gameName.trim()) {
      onCreateGame(gameName.trim());
      setGameName('');
    }
  };

  return (
    <div className="create-game">
      <h2>Create New Game</h2>
      <form onSubmit={handleSubmit} className="form">
        <div>
          <label className="label">
            Game Name:
          </label>
          <input
            type="text"
            value={gameName}
            onChange={(e) => setGameName(e.target.value)}
            placeholder="Enter game name..."
            className="input"
            required
          />
        </div>
        <button type="submit" className="button--primary button--large">
          Create Game
        </button>
      </form>
    </div>
  );
};