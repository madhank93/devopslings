"""The shop app, as run on web1 and web2.

It reads its settings from /ha/app.env and its health check from
/ha/app/health.py on every request, so an edit takes effect without a restart.

    GET  /            which node answered
    GET  /health      whatever /ha/app/health.py decides
    GET  /ping        the stack's own liveness probe; not for lessons
    GET  /cart        this session's cart          (cookie: sid)
    POST /cart?item=  add an item to it
    GET  /orders      count and newest order id, from the database
    POST /orders      place one; answers with its id
    GET  /db          which database server answered, and whether it is a standby
    GET  /<name>      /ha/app/routes/<name>.py, when it exists: handle(db) returns
                      (status, body) or (status, body, {headers}); a dict body
                      is sent as JSON

/ha/app/scheduler.sh, when it exists, runs as a background job on each node:
restarted a second after it exits, and restarted at once when the file changes.
Its output goes to /ha/<node>/scheduler.log.
"""
import importlib.util
import json
import os
import signal
import socket
import subprocess
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg

NODE = socket.gethostname()
DEFAULT_DSN = "host=pg1 dbname=shop user=postgres password=devopslings connect_timeout=2"

_memory_sessions = {}
_lock = threading.Lock()
_cache = {}


def _load(path, parse):
    """Re-read path when its mtime changes; None while it does not exist."""
    try:
        mtime = os.stat(path).st_mtime
    except FileNotFoundError:
        return None
    hit = _cache.get(path)
    if hit and hit[0] == mtime:
        return hit[1]
    value = parse(path)
    _cache[path] = (mtime, value)
    return value


def _parse_env(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


def _parse_module(path):
    spec = importlib.util.spec_from_file_location("health", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def setting(key, default):
    return (_load("/ha/app.env", _parse_env) or {}).get(key, default)


def db():
    """A new connection per call, so a changed DB_DSN applies to the next request."""
    return psycopg.connect(setting("DB_DSN", DEFAULT_DSN), autocommit=True)


def session_get(sid):
    if setting("SESSION_STORE", "memory") == "postgres":
        with db() as c:
            row = c.execute("SELECT items FROM sessions WHERE sid = %s", (sid,)).fetchone()
        return row[0] if row else []
    with _lock:
        return list(_memory_sessions.get(sid, []))


def session_add(sid, item):
    if setting("SESSION_STORE", "memory") == "postgres":
        with db() as c:
            c.execute(
                "INSERT INTO sessions (sid, items) VALUES (%s, %s::jsonb) "
                "ON CONFLICT (sid) DO UPDATE SET items = sessions.items || EXCLUDED.items",
                (sid, json.dumps([item])),
            )
        return session_get(sid)
    with _lock:
        _memory_sessions.setdefault(sid, []).append(item)
        return list(_memory_sessions[sid])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"{NODE} {self.address_string()} {fmt % args}", flush=True)

    def reply(self, code, body, cookie=None, headers=None):
        data = (body if isinstance(body, str) else json.dumps(body)) + "\n"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain" if isinstance(body, str) else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Served-By", NODE)
        if cookie:
            self.send_header("Set-Cookie", f"sid={cookie}; Path=/")
        for k, v in (headers or {}).items():
            self.send_header(k, str(v))
        self.end_headers()
        self.wfile.write(data.encode())

    def sid(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "sid" and v:
                return v, None
        new = uuid.uuid4().hex
        return new, new

    def route(self, method):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/ping":
            return self.reply(200, "pong")
        if url.path == "/" and method == "GET":
            return self.reply(200, f"hello from {NODE}")
        if url.path == "/health":
            mod = _load("/ha/app/health.py", _parse_module)
            if mod is None:
                return self.reply(200, "ok")
            result = mod.check(db)
            ok, detail = result if isinstance(result, tuple) else (bool(result), "")
            return self.reply(200 if ok else 503, f"{'ok' if ok else 'unhealthy'} {detail}".strip())
        if url.path == "/cart":
            sid, new = self.sid()
            if method == "POST":
                items = session_add(sid, q.get("item", ["thing"])[0])
            else:
                items = session_get(sid)
            return self.reply(200, {"node": NODE, "sid": sid, "items": items}, cookie=new)
        if url.path == "/orders":
            with db() as c:
                if method == "POST":
                    ref = q.get("ref", [uuid.uuid4().hex[:12]])[0]
                    oid = c.execute(
                        "INSERT INTO orders (reference) VALUES (%s) RETURNING id", (ref,)
                    ).fetchone()[0]
                    return self.reply(200, {"node": NODE, "id": oid, "reference": ref})
                n, top = c.execute("SELECT count(*), coalesce(max(id), 0) FROM orders").fetchone()
            return self.reply(200, {"node": NODE, "count": n, "newest": top})
        if url.path == "/db":
            with db() as c:
                addr, standby = c.execute(
                    "SELECT host(inet_server_addr()), pg_is_in_recovery()"
                ).fetchone()
            return self.reply(200, {"node": NODE, "server": addr, "standby": standby})
        route = f"/ha/app/routes/{url.path.strip('/')}.py"
        if method == "GET" and "/" not in url.path.strip("/") and os.path.exists(route):
            mod = _load(route, _parse_module)
            code, body, *rest = mod.handle(db)
            return self.reply(code, body, headers=rest[0] if rest else None)
        return self.reply(404, "not found")

    def handle_one(self, method):
        # An unread body would be parsed as the next request on this connection.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        try:
            self.route(method)
        except Exception as e:  # the client gets the reason; the log gets the trace
            traceback.print_exc()
            self.reply(500, f"error on {NODE}: {type(e).__name__}: {str(e).strip()}")

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")


def run_scheduler(path="/ha/app/scheduler.sh"):
    """Keep one copy of path running while it exists; restart it when it changes."""
    proc, started_mtime = None, None
    os.makedirs(f"/ha/{NODE}", exist_ok=True)
    while True:
        try:
            mtime = os.stat(path).st_mtime
        except FileNotFoundError:
            mtime = None
        if proc and (mtime != started_mtime or proc.poll() is not None):
            if proc.poll() is None:
                # The whole process group: a script's children must not outlive it.
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            proc = None
            time.sleep(1)
            continue
        if proc is None and mtime is not None:
            log = open(f"/ha/{NODE}/scheduler.log", "a")
            proc = subprocess.Popen(["bash", path], stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            log.close()
            started_mtime = mtime
        time.sleep(0.5)


if __name__ == "__main__":
    threading.Thread(target=run_scheduler, daemon=True).start()
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
