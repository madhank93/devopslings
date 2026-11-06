"""db — the database shop depends on, reduced to one endpoint. Metrics on :9101.

Every query borrows one of POOL_SIZE connections and is refused with a 503 when
none comes free within a second. While /obs/run/db.fault exists, a migration
holds a lock that every query waits on, with its connection checked out.
"""
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import Counter, Gauge, start_http_server

POOL_SIZE = 2

QUERIES = Counter("db_queries_total", "Queries answered.")
IN_USE = Gauge("db_pool_connections_in_use", "Connections checked out of the pool right now.")
MAX = Gauge("db_pool_connections_max", "Connections the pool can hand out at once.")
WAITING = Gauge("db_pool_waiting_queries", "Queries waiting for a connection to come free.")
TIMEOUTS = Counter("db_pool_acquire_timeouts_total",
                   "Queries refused because no connection came free within 1s.")
MAX.set(POOL_SIZE)
pool = threading.Semaphore(POOL_SIZE)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with WAITING.track_inprogress():
            got = pool.acquire(timeout=1)
        if not got:
            TIMEOUTS.inc()
            return self.reply(503, b"no connection\n")
        try:
            with IN_USE.track_inprogress():
                locked = os.path.exists("/obs/run/db.fault")
                time.sleep(random.uniform(1.0, 1.5) if locked else 0.005)
                QUERIES.inc()
        finally:
            pool.release()
        self.reply(200, b"ok\n")


start_http_server(9101)
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
