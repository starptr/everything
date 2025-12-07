import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { Server } from 'socket.io';
import { setupSocketIO } from './websocket';
import { setupRoutes } from './routes';
import { ClientToServerEvents, ServerToClientEvents } from '../types';

const app = express();
const server = createServer(app);
const io = new Server<ClientToServerEvents, ServerToClientEvents>(server, {
  cors: {
    origin: 'http://localhost:3000',
    methods: ['GET', 'POST'],
    credentials: true
  }
});

// Configure CORS to allow requests from frontend
app.use(cors({
  origin: 'http://localhost:3000',
  credentials: true
}));

app.use(express.json());

app.use('/api', setupRoutes());

// Make io instance available globally for broadcast functions
declare global {
  var io: Server<ClientToServerEvents, ServerToClientEvents>;
}
global.io = io;

setupSocketIO(io);

app.use(express.static('dist/client'));

const PORT = process.env.PORT || 8000;

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});