-- This script runs automatically the first time the Postgres container starts.
-- The official postgres image executes any .sql or .sh file in /docker-entrypoint-initdb.d/

CREATE TABLE IF NOT EXISTS pets (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    species VARCHAR(50) NOT NULL,
    price_cents INTEGER NOT NULL,
    stock INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    pet_id INTEGER NOT NULL REFERENCES pets(id),
    quantity INTEGER NOT NULL,
    total_cents INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    customer_email VARCHAR(200),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created_at ON orders(created_at);

-- Seed data so the app has something to show
INSERT INTO pets (name, species, price_cents, stock) VALUES
    ('Rex',      'dog',    25000, 5),
    ('Whiskers', 'cat',    15000, 8),
    ('Bubbles',  'fish',   1500,  50),
    ('Tweety',   'bird',   8000,  12),
    ('Slinky',   'snake',  35000, 3),
    ('Hopper',   'rabbit', 12000, 7),
    ('Spike',    'dog',    28000, 4),
    ('Mittens',  'cat',    16500, 6);
