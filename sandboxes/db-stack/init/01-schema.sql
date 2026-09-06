-- Schema and seed for db-stack. Runs once, on the primary's first start.
--
-- Ten million orders. Large enough that the planner's choices are real: on a
-- small table it will pick a sequential scan whatever you index, which would
-- teach students the opposite of every lesson in this module.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- The replica attaches as this role.
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicate';

CREATE TABLE customers (
    id          bigserial PRIMARY KEY,
    email       text NOT NULL,
    country     text NOT NULL,
    created_at  timestamptz NOT NULL
);

CREATE TABLE orders (
    id           bigserial PRIMARY KEY,
    customer_id  bigint NOT NULL REFERENCES customers(id),
    status       text NOT NULL,
    -- Stored as text on purpose. The-index-that-is-not-used turns on a query
    -- comparing this to a number, which makes the planner wrap the column in a
    -- cast and skip the index on it.
    reference    text NOT NULL,
    total_cents  bigint NOT NULL,
    placed_at    timestamptz NOT NULL
);

INSERT INTO customers (email, country, created_at)
SELECT
    'customer' || g || '@example.invalid',
    (ARRAY['GB','US','DE','FR','IN'])[1 + (g % 5)],
    now() - (g % 900) * interval '1 day'
FROM generate_series(1, 200000) AS g;

INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
SELECT
    1 + (g % 200000),
    (ARRAY['placed','picked','shipped','delivered','cancelled'])[1 + (g % 5)],
    (1000000 + g)::text,
    100 + (g % 90000),
    now() - (g % 900) * interval '1 day'
FROM generate_series(1, 10000000) AS g;

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_placed_at_idx   ON orders (placed_at);
CREATE INDEX orders_reference_idx   ON orders (reference);

ANALYZE customers;
ANALYZE orders;
