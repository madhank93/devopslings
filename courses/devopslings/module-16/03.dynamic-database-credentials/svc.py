"""A service that gets its database credential from OpenBao, once.

DB_CREDS is the OpenBao path to read: a KV v2 secret (secret/data/...) or a
database role (database/creds/...). The credential is fetched on the first
request and kept for the life of the process, as most applications do.

GET /health opens a fresh connection with it and reports, one per line:
  user=  lease=  source=  and error= when something failed.
"""
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

SERVICE = os.environ["SERVICE"]
SOURCE = os.environ.get("DB_CREDS", "")
creds = {}


def fetch():
    req = urllib.request.Request(f"{os.environ['BAO_ADDR']}/v1/{SOURCE}",
                                 headers={"X-Vault-Token": os.environ.get("BAO_TOKEN", "")})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:
        try:
            detail = "; ".join(json.load(e).get("errors", []))
        except ValueError:
            detail = e.reason
        raise RuntimeError(f"OpenBao refused {SOURCE}: HTTP {e.code} {detail}")
    data = body["data"]
    data = data.get("data", data)  # KV v2 nests the secret one level down
    return {"user": data["username"], "password": data["password"],
            "lease": body.get("lease_id", "")}


def health():
    lines = [f"service={SERVICE}", f"source={SOURCE}"]
    try:
        if not creds:
            creds.update(fetch())
        lines += [f"user={creds['user']}", f"lease={creds['lease']}"]
        with psycopg.connect(host="db", dbname="app", user=creds["user"],
                             password=creds["password"], connect_timeout=3) as conn:
            conn.execute("SELECT count(*) FROM ledger").fetchone()
        return 200, lines
    except Exception as e:
        return 500, lines + ["error=" + " ".join(str(e).split())]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        code, lines = health()
        data = ("\n".join(lines) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print(f"{SERVICE} listening on :8080")
ThreadingHTTPServer(("", 8080), Handler).serve_forever()
