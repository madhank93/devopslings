"""ledger — records fulfilled orders. POST /entries on :8080."""
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from opentelemetry import propagate, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("ledger")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        ctx = propagate.extract(self.headers)
        with tracer.start_as_current_span("POST /entries", context=ctx, kind=trace.SpanKind.SERVER):
            time.sleep(0.01)
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
