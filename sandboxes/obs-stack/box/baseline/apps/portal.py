"""portal — the customer login page, over HTTPS on :8443. Metrics on :9101.

GET /login serves the sign-in form. While /obs/run/portal.fault exists, the
page behind it is broken and /login serves the error page instead, still with
status 200, so every request counts as a success in portal_http_requests_total.

The certificate is /obs/portal/tls.crt. When it is missing, portal makes a
self-signed one on start, valid for the number of days in /obs/portal/cert-days
(365 if that file is absent). A replaced certificate is served from the next
connection on, without a restart.
"""
import os
import ssl
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import Counter, start_http_server

DIR = "/obs/portal"
CRT, KEY = f"{DIR}/tls.crt", f"{DIR}/tls.key"
REQS = Counter("portal_http_requests", "Requests portal answered.", ["path", "code"])

FORM = b"""<!doctype html><title>Sign in</title>
<form id="login" method="post" action="/login">
<input name="user"><input name="password" type="password"><button>Sign in</button>
</form>
"""
ERROR = b"""<!doctype html><title>Sign in</title>
<h1>Sorry, something went wrong.</h1><p>Please try again later.</p>
"""


def ensure_cert():
    if os.path.exists(CRT) and os.path.exists(KEY):
        return
    os.makedirs(DIR, exist_ok=True)
    try:
        days = int(open(f"{DIR}/cert-days").read().strip())
    except (OSError, ValueError):
        days = 365
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", str(days),
                    "-subj", "/CN=portal", "-addext", "subjectAltName=DNS:portal",
                    "-keyout", KEY, "-out", CRT], check=True, capture_output=True)
    os.chmod(KEY, 0o644)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/login":
            self.reply(404, b"not found\n")
        elif os.path.exists("/obs/run/portal.fault"):
            self.reply(200, ERROR)
        else:
            self.reply(200, FORM)

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        REQS.labels(self.path.split("?")[0], str(code)).inc()

    def log_message(self, *args):
        pass


def reload_cert(ctx):
    seen = os.stat(CRT).st_mtime
    while True:
        time.sleep(1)
        try:
            mtime = os.stat(CRT).st_mtime
            if mtime != seen:
                ctx.load_cert_chain(CRT, KEY)
                seen = mtime
        except (OSError, ssl.SSLError):
            pass


ensure_cert()
start_http_server(9101)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CRT, KEY)
threading.Thread(target=reload_cert, args=(ctx,), daemon=True).start()
server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
