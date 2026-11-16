"""billing — issues invoices and logs each one to the Collector over OTLP/HTTP.

A steady trickle all the time, and every 30 seconds a settlement run that
logs 125 lines in one request. Every record carries a sequence number, and
billing_log_records_total on :9101 counts what billing handed to the
Collector, so the two can be compared.
"""
import json
import threading
import time
import urllib.request

from prometheus_client import Counter, start_http_server

SENT = Counter("billing_log_records", "Log records billing handed to the Collector.")
URL = "http://collector:4318/v1/logs"
seq = 0
seq_lock = threading.Lock()


def next_seq():
    global seq
    with seq_lock:
        seq += 1
        return seq


def ship(lines):
    """One OTLP request. The Collector's answer is not read: billing logs and moves on."""
    now = str(time.time_ns())
    records = [{"timeUnixNano": now, "severityText": "INFO", "body": {"stringValue": text},
                "attributes": [{"key": "seq", "value": {"intValue": str(n)}}]} for n, text in lines]
    body = {"resourceLogs": [{"resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": "billing"}}]},
        "scopeLogs": [{"logRecords": records}]}]}
    try:
        req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass
    SENT.inc(len(lines))


def invoice_line():
    n = next_seq()
    return n, f"invoice issued seq={n} amount={n % 9000 + 100}"


start_http_server(9101)
last = time.time()
while True:
    ship([invoice_line()])
    if time.time() - last >= 30:
        last = time.time()
        ship([invoice_line() for _ in range(125)])
    time.sleep(0.1)
