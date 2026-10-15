"""greeter: calls a weather partner's API with a key it holds in memory.

GET /status reports which key it holds as a fingerprint, sha256(key)[:12].
Keep that endpoint as it is: it is what the check reads.
"""
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


def load_key():
    return os.environ.get("PARTNER_API_KEY", "")


KEY = load_key()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/status":
            self.send_error(404)
            return
        if KEY:
            code, body = 200, {"status": "ok",
                               "key_fingerprint": hashlib.sha256(KEY.encode()).hexdigest()[:12]}
        else:
            code, body = 500, {"status": "error", "error": "no partner API key"}
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print("greeter listening on :8080")
HTTPServer(("", 8080), Handler).serve_forever()
