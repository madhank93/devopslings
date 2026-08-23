#!/usr/bin/env python3

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# One program, two boxes' worth of roles: the ports and the name come from the
# environment so the same file can be a second, independently controllable
# backend. A lesson that needs one upstream dead and another slow needs two
# processes, because the mode is process-wide.
NAME = os.environ.get("UPSTREAM_NAME", "a")
PORT = int(os.environ.get("UPSTREAM_PORT", "8080"))
ADMIN_PORT = int(os.environ.get("UPSTREAM_ADMIN_PORT", "8081"))

LOCK = threading.Lock()
RECEIVED = []
LAST = {}
MODE = {"mode": "normal", "ms": 0}


def respond(handler, code, body, ctype="text/plain"):
    handler.send_response(code)
    handler.send_header("Content-Type", ctype)
    handler.send_header("X-Upstream", NAME)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


ROUTES = {
    "/users": b"users: alice bob carol\n",
    "/orders": b"orders: 1001 1002\n",
    "/version": b"upstream 1.0\n",
    "/health": b"ok\n",
    "/pages/intro": b"docs: introduction\n",
}


class Service(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # The raw request target is recorded exactly as it arrived, duplicate
    # slashes and all. What a proxy sent is the evidence; normalising it here
    # would erase the thing these lessons are about.
    def record(self):
        with LOCK:
            RECEIVED.append("%s %s" % (self.command, self.path))
            del RECEIVED[:-200]
            LAST.clear()
            LAST.update({
                "method": self.command,
                "path": self.path,
                "headers": {k: v for k, v in self.headers.items()},
            })

    # "dead" closes the connection with nothing written on it, which is what a
    # crashed upstream looks like to a proxy; "slow" is a live upstream that
    # answers past the proxy's read timeout.
    def gate(self):
        with LOCK:
            mode, ms = MODE["mode"], MODE["ms"]
        if mode == "dead":
            self.close_connection = True
            return False
        if mode == "slow":
            time.sleep(ms / 1000.0)
        return True

    def do_GET(self):
        self.record()
        if not self.gate():
            return
        path = urlsplit(self.path).path
        if path == "/whoami":
            respond(self, 200, ("upstream: %s\n" % NAME).encode())
        elif path in ROUTES:
            respond(self, 200, ROUTES[path])
        else:
            respond(self, 404, ("no route: %s\n" % path).encode())

    def do_POST(self):
        self.record()
        if not self.gate():
            return
        path = urlsplit(self.path).path
        if path != "/upload":
            respond(self, 404, ("no route: %s\n" % path).encode())
            return
        want = int(self.headers.get("Content-Length", "0"))
        got = 0
        while got < want:
            chunk = self.rfile.read(min(65536, want - got))
            if not chunk:
                break
            got += len(chunk)
        respond(self, 200, ("stored bytes=%d\n" % got).encode())


class Admin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/admin/received":
            with LOCK:
                body = "\n".join(RECEIVED) + "\n"
            respond(self, 200, body.encode(), "text/plain")
        elif parsed.path == "/admin/last":
            with LOCK:
                body = json.dumps(LAST)
            respond(self, 200, body.encode(), "application/json")
        else:
            respond(self, 404, b"no admin route\n")

    def do_POST(self):
        parsed = urlsplit(self.path)
        qs = parse_qs(parsed.query)
        if parsed.path == "/admin/mode":
            value = qs.get("value", ["normal"])[0]
            ms = qs.get("ms", ["0"])[0]
            if value not in ("normal", "slow", "dead"):
                respond(self, 400, b"bad mode\n")
                return
            with LOCK:
                MODE["mode"] = value
                MODE["ms"] = int(ms)
            respond(self, 200, ("mode=%s ms=%d\n" % (value, int(ms))).encode())
        elif parsed.path == "/admin/reset":
            with LOCK:
                del RECEIVED[:]
                LAST.clear()
                MODE["mode"] = "normal"
                MODE["ms"] = 0
            respond(self, 200, b"reset\n")
        else:
            respond(self, 404, b"no admin route\n")


if __name__ == "__main__":
    admin = ThreadingHTTPServer(("0.0.0.0", ADMIN_PORT), Admin)
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Service).serve_forever()
