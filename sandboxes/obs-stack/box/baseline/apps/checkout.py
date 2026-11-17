"""checkout — takes orders and publishes each one to broker for fulfil.

Customers are simulated in-process: an order every few hundred milliseconds.
Each order is one trace. Metrics on :9101.
"""
import json
import random
import time
import urllib.request

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Histogram, start_http_server

provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("checkout")

DURATION = Histogram("checkout_duration_seconds", "Time to take one order, end to end.",
                     buckets=(0.05, 0.1, 0.25, 0.5, 1, 2, 4))


def apply_coupon():
    """The coupon service answers fast or not at all; a timeout is retried once."""
    with tracer.start_as_current_span("coupon.lookup"):
        for attempt in (1, 2):
            with tracer.start_as_current_span("coupon.attempt") as s:
                s.set_attribute("attempt", attempt)
                if attempt == 1 and random.random() < 0.3:
                    time.sleep(1.0)
                    s.set_status(trace.StatusCode.ERROR, "timed out after 1s")
                    continue
                time.sleep(random.uniform(0.01, 0.03))
                return


def publish(order):
    with tracer.start_as_current_span("publish orders", kind=trace.SpanKind.PRODUCER):
        req = urllib.request.Request("http://broker:8080/publish", data=json.dumps(order).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=2).read()


def take_order(n):
    start = time.perf_counter()
    with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER) as span:
        order = {"order_id": f"ord-{n}", "items": random.randint(1, 5)}
        span.set_attribute("order.id", order["order_id"])
        with tracer.start_as_current_span("price"):
            time.sleep(random.uniform(0.02, 0.08))
        if random.random() < 0.1:
            span.set_attribute("order.coupon", True)
            apply_coupon()
        publish(order)
    DURATION.observe(time.perf_counter() - start)


start_http_server(9101)
n = int(time.time()) % 100000 * 100
while True:
    n += 1
    try:
        take_order(n)
    except Exception as e:
        print(f"order {n} failed: {e}", flush=True)
        time.sleep(1)
    time.sleep(random.uniform(0.2, 0.4))
