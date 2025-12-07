import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { setupWebSocket } from './websocket';
import { setupRoutes } from './routes';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

// Configure CORS to allow requests from frontend
app.use(cors({
  origin: 'http://localhost:3000',
  credentials: true
}));

app.use(express.json());

app.use('/api', setupRoutes());

setupWebSocket(wss);

app.use(express.static('dist/client'));

const PORT = process.env.PORT || 8000;

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});