"""search — answers in about 5ms, except while it is paused.

Every PAUSE_EVERY seconds the process stops the world for PAUSE_FOR seconds, the
way a stop-the-world garbage collection does: a request that arrives during the
pause waits for it to end, and so does every request already in progress.
"""
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAUSE_EVERY, PAUSE_FOR, WORK = 5.0, 1.0, 0.005
world = threading.Lock()


def collector():
    while True:
        time.sleep(PAUSE_EVERY - PAUSE_FOR)
        with world:
            time.sleep(PAUSE_FOR)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with world:
            pass
        time.sleep(WORK)
        with world:
            pass
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


threading.Thread(target=collector, daemon=True).start()
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8200), H).serve_forever()
