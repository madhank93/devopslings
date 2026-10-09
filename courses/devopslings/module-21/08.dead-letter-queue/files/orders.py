"""orders — the queue's schema and the downstream every message is handed to.

This file is the lesson's, not yours: the check deploys its own copy, so an
edit here changes what you see locally and nothing that is graded.

    python3 orders.py seed            # 30 well-formed orders
    python3 orders.py seed --poison   # the same, with order 4 malformed
"""

import json
import os
import sqlite3
import sys

DB = "/srv/queue/queue.db"

SCHEMA = """
CREATE TABLE messages (
  id         INTEGER PRIMARY KEY,
  body       TEXT    NOT NULL,
  status     TEXT    NOT NULL DEFAULT 'pending',
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
-- Where a message that will never succeed is parked for a human to look at.
CREATE TABLE dead_letter (
  id         INTEGER PRIMARY KEY,
  message_id INTEGER NOT NULL,
  body       TEXT    NOT NULL,
  error      TEXT,
  attempts   INTEGER,
  parked_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- Downstream state, written by handle(). Not the queue's.
CREATE TABLE shipped (order_id INTEGER NOT NULL, sku TEXT NOT NULL, qty INTEGER NOT NULL);
CREATE TABLE stock_busy (order_id INTEGER PRIMARY KEY);
"""

POISON_ORDER = 4


class StockBusy(Exception):
    """Transient: the same call succeeds when retried."""


def connect():
    return sqlite3.connect(DB, timeout=10)


def handle(body):
    """Ship one order. Raises on failure; returns normally on success."""
    order = json.loads(body)
    order_id = int(order["order"])
    qty = int(order["qty"])
    with connect() as conn:
        # The stock service is briefly busy for every fifth order: the first
        # call fails and any later one succeeds.
        if order_id % 5 == 0 and conn.execute(
            "INSERT OR IGNORE INTO stock_busy VALUES (?)", (order_id,)
        ).rowcount:
            conn.commit()
            raise StockBusy(f"stock service busy for order {order_id}, try again")
        conn.execute(
            "INSERT INTO shipped VALUES (?, ?, ?)", (order_id, order["sku"], qty)
        )


def order_body(n, poison):
    qty = "two" if poison and n == POISON_ORDER else 1 + n % 3
    return json.dumps({"order": n, "sku": f"MUG-{n % 4:02d}", "qty": qty})


def stop_consumers():
    """A consumer left running from an earlier run would race the next one."""
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if any(a.endswith(b"consumer.py") for a in argv[1:2]):
            try:
                os.kill(int(pid), 9)
            except OSError:
                pass


def seed(poison):
    stop_consumers()
    for suffix in ("", "-wal", "-shm", "-journal"):
        try:
            os.remove(DB + suffix)
        except FileNotFoundError:
            pass
    with connect() as conn:
        conn.executescript(SCHEMA)
        conn.executemany(
            "INSERT INTO messages (body) VALUES (?)",
            [(order_body(n, poison),) for n in range(1, 31)],
        )


if __name__ == "__main__":
    if sys.argv[1:2] != ["seed"]:
        sys.exit(__doc__)
    seed("--poison" in sys.argv)
    print("queue seeded:", "30 orders, order 4 malformed" if "--poison" in sys.argv else "30 orders")
