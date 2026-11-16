"""loadgen — steady customer traffic against shop and orders.

It measures what customers saw, on :9101, so a check has a ground truth to hold
an app's own metrics against.
"""
import random
import threading
import time
import urllib.error
import urllib.request

from prometheus_client import Counter, Histogram, start_http_server

SEEN = Counter("loadgen_requests_total", "Requests sent, by target and the status code received.",
               ["target", "code"])
TOOK = Histogram("loadgen_request_duration_seconds", "Response time as the customer saw it.",
                 ["target"], buckets=[i / 100 for i in range(1, 100)] + [1.25, 1.5, 2, 3, 5])


def hit(target, url):
    start = time.time()
    try:
        code = urllib.request.urlopen(url, timeout=5).status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        code = 0
    SEEN.labels(target, str(code)).inc()
    if code:
        TOOK.labels(target).observe(time.time() - start)


def shop():
    while True:
        r = random.random()
        path = "/" if r < 0.4 else "/search" if r < 0.6 else "/cart" if r < 0.8 \
            else f"/orders/{random.randint(1000, 99999)}"
        hit("shop", "http://shop:8080" + path)
        time.sleep(random.uniform(0.1, 0.5))


def orders():
    while True:
        hit("orders", "http://orders:8080/order")
        time.sleep(random.uniform(0.1, 0.5))


start_http_server(9101)
for fn in [shop] * 4 + [orders] * 4:
    threading.Thread(target=fn, daemon=True).start()
while True:
    time.sleep(3600)
