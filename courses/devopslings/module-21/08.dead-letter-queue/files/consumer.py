"""consumer — drains the order queue, oldest message first, then exits.

Each pending message in `messages` is handed to orders.handle(). A message
that is handled is marked done; one that raises is retried, because the stock
service it calls is sometimes briefly busy.
"""

import sqlite3
import time

from orders import DB, handle


def main():
    conn = sqlite3.connect(DB, timeout=10)
    while True:
        row = conn.execute(
            "SELECT id, body FROM messages WHERE status = 'pending' ORDER BY id LIMIT 1"
        ).fetchone()
        if row is None:
            print("queue drained", flush=True)
            return
        msg_id, body = row
        try:
            handle(body)
        except Exception as exc:
            print(f"message {msg_id} failed: {exc!r}; retrying", flush=True)
            time.sleep(0.5)
            continue
        with conn:
            conn.execute("UPDATE messages SET status = 'done' WHERE id = ?", (msg_id,))
        print(f"message {msg_id} done", flush=True)


if __name__ == "__main__":
    main()
