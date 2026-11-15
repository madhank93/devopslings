"""shop — the storefront. Serves pages on :8080, metrics on :9101.

/cart and /orders/<id> read from db; when db is unreachable they answer 500.
While /obs/run/shop.fault exists, shop has a bug of its own and requests fail:
the fraction the file holds (0.05 is one in twenty), or 0.6 when it is empty.
"""
import random
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import Counter, Histogram, start_http_server

REQUESTS = Counter(
    "shop_http_requests_total", "HTTP requests served, by route template and status code.",
    ["method", "route", "code"])
LATENCY = Histogram(
    "shop_http_request_duration_seconds", "Time to serve an HTTP request.",
    ["route"], buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5))

ROUTES = {"/": 0.02, "/cart": 0.04, "/search": 0.15}


def route_of(path):
    path = path.split("?")[0]
    if path.startswith("/orders/"):
        return "/orders/:id"
    return path if path in ROUTES else None


def fault_rate():
    try:
        return float(open("/obs/run/shop.fault").read().strip() or 0.6)
    except OSError:
        return 0
    except ValueError:
        return 0.6


def db_query():
    urllib.request.urlopen("http://db:8080/query", timeout=1).read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        start = time.time()
        route = route_of(self.path)
        code = 200
        if route is None:
            code = 404
        else:
            time.sleep(random.expovariate(1 / ROUTES.get(route, 0.03)))
            if random.random() < fault_rate():
                code = 500
            elif route in ("/cart", "/orders/:id"):
                try:
                    db_query()
                except Exception:
                    code = 500
        body = b"ok\n" if code == 200 else b"error\n"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if route is not None:
            REQUESTS.labels("GET", route, str(code)).inc()
            LATENCY.labels(route).observe(time.time() - start)


start_http_server(9101)
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
