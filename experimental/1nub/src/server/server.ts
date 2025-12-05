import { Server } from 'boardgame.io/server';
import OneNightWerewolf from './game-simple';

const server = Server({
  games: [OneNightWerewolf],
  
  origins: [
    'http://localhost:3000',
    'http://localhost:1234',
    /.*\.ngrok\.io$/,
  ]
});

const PORT = parseInt(process.env.PORT || '8000');

server.run(PORT, () => {
  console.log(`Server running on port ${PORT}...`);
  console.log(`Game available at http://localhost:${PORT}`);
});