"""A service that reads its own config from OpenBao on every request.

GET /health reads secret/<SERVICE>/config and answers 200 if it could.
"""
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = os.environ["SERVICE"]
PATH = f"/v1/secret/data/{SERVICE}/config"


def read_config():
    req = urllib.request.Request(os.environ["BAO_ADDR"] + PATH,
                                 headers={"X-Vault-Token": os.environ.get("BAO_TOKEN", "")})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)["data"]["data"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        try:
            keys = sorted(read_config())
            code, body = 200, f"{SERVICE}: read secret/{SERVICE}/config ({', '.join(keys)})\n"
        except urllib.error.HTTPError as e:
            code, body = 500, f"{SERVICE}: cannot read secret/{SERVICE}/config: HTTP {e.code}\n"
        except Exception as e:
            code, body = 500, f"{SERVICE}: cannot reach OpenBao: {e}\n"
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print(f"{SERVICE} listening on :8080")
ThreadingHTTPServer(("", 8080), Handler).serve_forever()
