#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import struct
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

# Liveness and readiness are different questions. A process can be running
# perfectly while the thing it needs to do its job is gone, and a check that
# only proves the former keeps a useless node in rotation.
DEPS = {"state": "ok"}

# The build currently deployed. /asset.js changes with it, which is what makes
# a cache serving yesterday's copy visible rather than theoretical.
VERSION = {"n": 1}

# RFC 6455's fixed GUID: the server proves it understood the handshake by
# hashing it onto the client's key.
WS_GUID = "258EAFA5-E914-47DA-95CA-5AB0DC85B39A"


def ws_recv(rfile):
    hdr = rfile.read(2)
    if not hdr or len(hdr) < 2:
        return None, b""
    opcode = hdr[0] & 0x0F
    masked = hdr[1] & 0x80
    n = hdr[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", rfile.read(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", rfile.read(8))[0]
    mask = rfile.read(4) if masked else b""
    data = rfile.read(n) if n else b""
    if masked:
        data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
    return opcode, data


def ws_send(wfile, opcode, data=b""):
    # Server-to-client frames are never masked, and everything here fits in one
    # frame, so FIN is always set.
    head = bytearray([0x80 | opcode])
    n = len(data)
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    wfile.write(bytes(head) + data)
    wfile.flush()


def respond(handler, code, body, ctype="text/plain", extra=None):
    handler.send_response(code)
    handler.send_header("Content-Type", ctype)
    handler.send_header("X-Upstream", NAME)
    handler.send_header("Content-Length", str(len(body)))
    for k, v in (extra or {}).items():
        handler.send_header(k, v)
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
        with LOCK:
            deps = DEPS["state"]

        # /health answers for the process and nothing else, which is exactly the
        # trap; /ready answers for whether this node can actually serve.
        if path == "/health":
            respond(self, 200, b"ok\n")
        elif path == "/ready":
            if deps == "ok":
                respond(self, 200, b"ready\n")
            else:
                respond(self, 503, b"dependency unavailable\n")
        elif path == "/ws":
            self.websocket()
        elif path == "/asset.js":
            with LOCK:
                n = VERSION["n"]
            respond(
                self,
                200,
                ("console.log('build %d');\n" % n).encode(),
                "application/javascript",
                {"Cache-Control": "public, max-age=60", "ETag": '"build-%d"' % n},
            )
        elif path == "/profile":
            # The response depends on a request header, and says so. A cache
            # that does not read Vary will hand one user another's page.
            user = self.headers.get("X-User", "anonymous")
            respond(
                self,
                200,
                ("profile: %s\n" % user).encode(),
                "text/plain",
                {"Cache-Control": "public, max-age=60", "Vary": "X-User"},
            )
        elif path == "/whoami":
            respond(self, 200, ("upstream: %s\n" % NAME).encode())
        elif path in ROUTES:
            if deps == "ok":
                respond(self, 200, ROUTES[path])
            else:
                respond(self, 503, b"dependency unavailable\n")
        else:
            respond(self, 404, ("no route: %s\n" % path).encode())

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        upgrade = (self.headers.get("Upgrade") or "").lower()

        # A proxy that forwards the request without the hop-by-hop headers
        # arrives here looking like an ordinary GET, and this is what the client
        # then sees instead of a socket.
        if upgrade != "websocket" or not key:
            respond(self, 426, b"expected a websocket upgrade\n")
            return

        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()
        ).decode()
        self.wfile.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n"
                "X-Upstream: %s\r\n\r\n" % (accept, NAME)
            ).encode()
        )
        self.wfile.flush()
        self.close_connection = True

        while True:
            opcode, data = ws_recv(self.rfile)
            if opcode is None or opcode == 0x8:
                break
            if opcode == 0x9:
                ws_send(self.wfile, 0xA, data)
            elif opcode in (0x1, 0x2):
                ws_send(self.wfile, opcode, data)

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
        elif parsed.path == "/admin/deps":
            value = qs.get("value", ["ok"])[0]
            if value not in ("ok", "broken"):
                respond(self, 400, b"bad deps\n")
                return
            with LOCK:
                DEPS["state"] = value
            respond(self, 200, ("deps=%s\n" % value).encode())
        elif parsed.path == "/admin/deploy":
            n = qs.get("version", ["1"])[0]
            try:
                n = int(n)
            except ValueError:
                respond(self, 400, b"bad version\n")
                return
            with LOCK:
                VERSION["n"] = n
            respond(self, 200, ("version=%d\n" % n).encode())
        elif parsed.path == "/admin/reset":
            with LOCK:
                del RECEIVED[:]
                LAST.clear()
                MODE["mode"] = "normal"
                MODE["ms"] = 0
                DEPS["state"] = "ok"
                VERSION["n"] = 1
            respond(self, 200, b"reset\n")
        else:
            respond(self, 404, b"no admin route\n")


if __name__ == "__main__":
    admin = ThreadingHTTPServer(("0.0.0.0", ADMIN_PORT), Admin)
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Service).serve_forever()
