// catalog-service: serves the pet catalog from Postgres.
// Endpoints:
//   GET  /health         -> liveness probe
//   GET  /pets           -> list all pets
//   GET  /pets/:id       -> get one pet
//   POST /pets/:id/reserve  -> decrement stock by quantity (used by orders service)

const express = require('express');
const { Pool } = require('pg');
const pino = require('pino');
const pinoHttp = require('pino-http');

// --- Logger setup ---
// Structured JSON logs. Each log line is a JSON object with timestamp, level, message, and any extra fields.
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  formatters: {
    level: (label) => ({ level: label }),
  },
});

// --- Database connection pool ---
// Using a pool (not single connection) — this is a real-world pattern and gives us
// interesting connection-acquisition spans later.
const pool = new Pool({
  host: process.env.DB_HOST || 'postgres',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  user: process.env.DB_USER || 'petstore',
  password: process.env.DB_PASSWORD || 'petstore',
  database: process.env.DB_NAME || 'petstore',
  max: 10,
});

const app = express();
app.use(express.json());
app.use(pinoHttp({ logger })); // logs every HTTP request automatically

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'catalog' });
});

app.get('/pets', async (req, res) => {
  try {
    const result = await pool.query('SELECT id, name, species, price_cents, stock FROM pets ORDER BY id');
    req.log.info({ count: result.rows.length }, 'listed pets');
    res.json(result.rows);
  } catch (err) {
    req.log.error({ err }, 'failed to list pets');
    res.status(500).json({ error: 'database error' });
  }
});

app.get('/pets/:id', async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) return res.status(400).json({ error: 'invalid id' });

  try {
    const result = await pool.query('SELECT id, name, species, price_cents, stock FROM pets WHERE id = $1', [id]);
    if (result.rows.length === 0) {
      req.log.warn({ pet_id: id }, 'pet not found');
      return res.status(404).json({ error: 'pet not found' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    req.log.error({ err, pet_id: id }, 'failed to get pet');
    res.status(500).json({ error: 'database error' });
  }
});

app.post('/pets/:id/reserve', async (req, res) => {
  const id = parseInt(req.params.id, 10);
  const quantity = parseInt(req.body.quantity, 10) || 1;
  if (isNaN(id)) return res.status(400).json({ error: 'invalid id' });

  // Atomic decrement using a single UPDATE with a guard. Avoids the classic read-then-write race.
  try {
    const result = await pool.query(
      'UPDATE pets SET stock = stock - $1 WHERE id = $2 AND stock >= $1 RETURNING id, stock, price_cents',
      [quantity, id]
    );
    if (result.rows.length === 0) {
      req.log.warn({ pet_id: id, quantity }, 'reservation failed - insufficient stock or not found');
      return res.status(409).json({ error: 'insufficient stock' });
    }
    req.log.info({ pet_id: id, quantity, remaining: result.rows[0].stock }, 'reserved');
    res.json(result.rows[0]);
  } catch (err) {
    req.log.error({ err, pet_id: id }, 'reservation failed');
    res.status(500).json({ error: 'database error' });
  }
});

const port = parseInt(process.env.PORT || '3001', 10);
app.listen(port, () => {
  logger.info({ port }, 'catalog-service listening');
});
