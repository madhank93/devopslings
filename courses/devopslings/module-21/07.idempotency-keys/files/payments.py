"""payments — records a charge for every POST /charge.

The `charges` table is the ledger: one row is one customer charged once. The
lesson's check reads it directly, so keep the table and its id, customer and
amount columns. Anything else in the schema is yours to change.
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


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.post("/charge")
def charge():
    body = request.get_json(force=True)
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO charges (customer, amount) VALUES (?, ?)",
            (body["customer"], body["amount"]),
        )
        charge_id = cur.lastrowid
    return jsonify(charge_id=charge_id, customer=body["customer"], amount=body["amount"])


if __name__ == "__main__":
    from waitress import serve

    init_db()
    print("payments up on :8081", flush=True)
    serve(app, host="0.0.0.0", port=8081, threads=8)
