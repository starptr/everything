import { Server, Origins } from 'boardgame.io/server';
import { OneNightWerewolf } from './game';
import path from 'path';
import express from 'express';
import cors from 'cors';

const PORT = process.env.PORT || 8000;
const CLIENT_PORT = process.env.CLIENT_PORT || 1234;

// Create the main server
const server = Server({
  games: [OneNightWerewolf],
  
  // Allow connections from the client during development
  origins: [
    Origins.LOCALHOST,
    `http://localhost:${CLIENT_PORT}`,
    'http://localhost:3000', // Common React dev server port
  ],
});

// Create Express app for additional routes
const app = express();

// Enable CORS for client connections
app.use(cors({
  origin: [
    `http://localhost:${CLIENT_PORT}`,
    'http://localhost:3000',
  ],
  credentials: true,
}));

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    game: 'OneNightWerewolf',
    timestamp: new Date().toISOString(),
  });
});

// API routes for game management
app.get('/api/games', (req, res) => {
  res.json({
    available: ['OneNightWerewolf'],
    description: 'One Night Ultimate Werewolf - A social deduction game'
  });
});

// Development: Serve client files in production
if (process.env.NODE_ENV === 'production') {
  const clientPath = path.join(__dirname, '../../client/dist');
  app.use(express.static(clientPath));
  
  app.get('*', (req, res) => {
    res.sendFile(path.join(clientPath, 'index.html'));
  });
}

// Mount the boardgame.io server
app.use('/api', server.app);

app.listen(PORT, () => {
  console.log(`🐺 One Night Ultimate Werewolf server running on port ${PORT}`);
  console.log(`🎮 Game API available at http://localhost:${PORT}/api`);
  console.log(`💓 Health check at http://localhost:${PORT}/health`);
  
  if (process.env.NODE_ENV === 'development') {
    console.log(`🔧 Development mode - client should run on port ${CLIENT_PORT}`);
    console.log(`🌐 Connect client to http://localhost:${PORT}/api`);
  }
});