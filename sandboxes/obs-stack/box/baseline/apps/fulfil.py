"""fulfil — takes orders off broker's queue and records each one with ledger."""
import json
import random
import time
import urllib.request

from opentelemetry import propagate, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "fulfil"}))
provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("fulfil")


def record(order):
    headers = {"Content-Type": "application/json"}
    propagate.inject(headers)  # the trace continues into ledger over HTTP
    req = urllib.request.Request("http://ledger:8080/entries", data=json.dumps(order).encode(),
                                 headers=headers)
    urllib.request.urlopen(req, timeout=2).read()


def handle(message):
    order = json.loads(message)
    with tracer.start_as_current_span("process orders", kind=trace.SpanKind.CONSUMER) as span:
        span.set_attribute("order.id", order.get("order_id", ""))
        time.sleep(random.uniform(0.02, 0.06))  # pick and pack
        record(order)


while True:
    try:
        resp = urllib.request.urlopen("http://broker:8080/consume", timeout=2)
        message = resp.read()
        if resp.status == 204 or not message:
            time.sleep(0.1)
            continue
        handle(message)
    except Exception as e:
        print(f"fulfil: {e}", flush=True)
        time.sleep(1)
