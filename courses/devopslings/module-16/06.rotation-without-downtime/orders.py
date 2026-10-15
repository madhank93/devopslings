"""orders: every request opens a database connection with the credential in
OpenBao at secret/orders/db.

The credential is fetched at most every CRED_TTL seconds and cached in between,
so a change in OpenBao reaches this process up to CRED_TTL seconds late.

The secret holds `username` and `password`. If it also holds
`previous_password`, a login refused with one is retried with the other.
"""
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

CRED_TTL = 10
cache = {"at": 0.0, "creds": None}
lock = threading.Lock()


def creds():
    with lock:
        if cache["creds"] is None or time.time() - cache["at"] >= CRED_TTL:
            req = urllib.request.Request(os.environ["BAO_ADDR"] + "/v1/secret/data/orders/db",
                                         headers={"X-Vault-Token": os.environ["BAO_TOKEN"]})
            with urllib.request.urlopen(req, timeout=3) as resp:
                cache["creds"] = json.load(resp)["data"]["data"]
            cache["at"] = time.time()
        return cache["creds"]


def count_orders(user, password):
    with psycopg.connect(host="db", dbname="app", user=user, password=password,
                         connect_timeout=2) as conn:
        return conn.execute("SELECT count(*) FROM orders").fetchone()[0]


def handle():
    c = creds()
    if not c.get("previous_password"):
        return count_orders(c["username"], c["password"])
    # The password can change between two attempts, so the first is tried
    # again after the second.
    for pw in (c["password"], c["previous_password"], c["password"]):
        try:
            return count_orders(c["username"], pw)
        except psycopg.OperationalError as e:
            err = e
    raise err


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/order":
            self.send_error(404)
            return
        try:
            code, body = 200, f"ok orders={handle()}\n"
        except Exception as e:
            code, body = 500, "error " + " ".join(str(e).split()) + "\n"
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print("orders listening on :8080")
ThreadingHTTPServer(("", 8080), Handler).serve_forever()
