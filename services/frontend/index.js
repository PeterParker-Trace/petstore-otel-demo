// frontend: serves the static UI and proxies API calls to the gateway.
// Proxying via the same origin avoids CORS headaches and is closer to a real prod setup.

const express = require('express');
const axios = require('axios');
const pino = require('pino');
const pinoHttp = require('pino-http');
const path = require('path');

const logger = pino({ level: process.env.LOG_LEVEL || 'info' });

const app = express();
app.use(express.json());
app.use(pinoHttp({ logger }));
app.use(express.static(path.join(__dirname, 'public')));

const API_GATEWAY_URL = process.env.API_GATEWAY_URL || 'http://api-gateway:8000';

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'frontend' }));

// Proxy: anything under /api/* gets forwarded to the gateway.
app.all('/api/*', async (req, res) => {
  const url = `${API_GATEWAY_URL}${req.originalUrl}`;
  try {
    const response = await axios({
      method: req.method,
      url,
      data: req.body,
      validateStatus: () => true, // forward whatever status the gateway returned
    });
    res.status(response.status).json(response.data);
  } catch (err) {
    req.log.error({ err: err.message, url }, 'gateway proxy failed');
    res.status(502).json({ error: 'gateway unreachable' });
  }
});

const port = parseInt(process.env.PORT || '3000', 10);
app.listen(port, () => logger.info({ port, gateway: API_GATEWAY_URL }, 'frontend listening'));
