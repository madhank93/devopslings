-- Run once, by the postgres entrypoint, on pg1's first start.
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicate';

CREATE TABLE orders (
  id         bigserial PRIMARY KEY,
  reference  text NOT NULL,
  placed_at  timestamptz NOT NULL DEFAULT now()
);

-- The app's server-side session store, used when SESSION_STORE=postgres.
CREATE TABLE sessions (
  sid    text PRIMARY KEY,
  items  jsonb NOT NULL DEFAULT '[]'
);

INSERT INTO orders (reference)
SELECT 'SEED-' || g FROM generate_series(1, 1000) g;
