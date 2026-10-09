"""consumer — drains the order queue, oldest message first, then exits.

Each pending message in `messages` is handed to orders.handle(). A message
that is handled is marked done; one that raises is retried, because the stock
service it calls is sometimes briefly busy — but only MAX_ATTEMPTS times.
After that it is moved to dead_letter with its last error, so it stops
blocking the messages behind it and a human can see what failed and why.
"""

import sqlite3
import time

from orders import DB, handle

MAX_ATTEMPTS = 5


def main():
    conn = sqlite3.connect(DB, timeout=10)
    while True:
        row = conn.execute(
            "SELECT id, body, attempts FROM messages WHERE status = 'pending' ORDER BY id LIMIT 1"
        ).fetchone()
        if row is None:
            print("queue drained", flush=True)
            return
        msg_id, body, attempts = row
        try:
            handle(body)
        except Exception as exc:
            attempts += 1
            error = repr(exc)
            with conn:
                if attempts >= MAX_ATTEMPTS:
                    conn.execute(
                        "INSERT INTO dead_letter (message_id, body, error, attempts)"
                        " VALUES (?, ?, ?, ?)",
                        (msg_id, body, error, attempts),
                    )
                    conn.execute(
                        "UPDATE messages SET status = 'dead', attempts = ?, last_error = ?"
                        " WHERE id = ?",
                        (attempts, error, msg_id),
                    )
                else:
                    conn.execute(
                        "UPDATE messages SET attempts = ?, last_error = ? WHERE id = ?",
                        (attempts, error, msg_id),
                    )
            if attempts >= MAX_ATTEMPTS:
                print(f"message {msg_id} parked after {attempts} attempts: {error}", flush=True)
            else:
                print(f"message {msg_id} failed ({attempts}/{MAX_ATTEMPTS}): {error}", flush=True)
                time.sleep(0.1 * 2 ** attempts)
            continue
        with conn:
            conn.execute("UPDATE messages SET status = 'done' WHERE id = ?", (msg_id,))
        print(f"message {msg_id} done", flush=True)


if __name__ == "__main__":
    main()
