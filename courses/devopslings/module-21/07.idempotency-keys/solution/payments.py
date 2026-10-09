"""payments — records a charge for every POST /charge.

The `charges` table is the ledger: one row is one customer charged once. The
lesson's check reads it directly, so keep the table and its id, customer and
amount columns. Anything else in the schema is yours to change.

A request carrying an Idempotency-Key is charged at most once: a replay of a
key already seen gets the original charge back instead of a new one.
"""

import sqlite3

from flask import Flask, jsonify, request

DB = "/srv/payments/ledger.db"

app = Flask(__name__)


def db():
    conn = sqlite3.connect(DB, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with db() as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS charges ("
            " id INTEGER PRIMARY KEY,"
            " customer TEXT NOT NULL,"
            " amount REAL NOT NULL)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS idempotency_keys ("
            " key TEXT PRIMARY KEY,"
            " charge_id INTEGER NOT NULL REFERENCES charges(id))"
        )


def answer(row):
    return jsonify(charge_id=row["id"], customer=row["customer"], amount=row["amount"])


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.post("/charge")
def charge():
    body = request.get_json(force=True)
    key = request.headers.get("Idempotency-Key")
    conn = db()
    try:
        # IMMEDIATE takes the write lock up front, so two concurrent requests
        # with the same key cannot both miss the lookup and both insert.
        conn.execute("BEGIN IMMEDIATE")
        if key:
            seen = conn.execute(
                "SELECT c.* FROM idempotency_keys k JOIN charges c ON c.id = k.charge_id"
                " WHERE k.key = ?",
                (key,),
            ).fetchone()
            if seen:
                conn.execute("COMMIT")
                return answer(seen)
        cur = conn.execute(
            "INSERT INTO charges (customer, amount) VALUES (?, ?)",
            (body["customer"], body["amount"]),
        )
        if key:
            conn.execute(
                "INSERT INTO idempotency_keys (key, charge_id) VALUES (?, ?)",
                (key, cur.lastrowid),
            )
        row = conn.execute("SELECT * FROM charges WHERE id = ?", (cur.lastrowid,)).fetchone()
        conn.execute("COMMIT")
        return answer(row)
    except Exception:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    from waitress import serve

    init_db()
    print("payments up on :8081", flush=True)
    serve(app, host="0.0.0.0", port=8081, threads=8)
