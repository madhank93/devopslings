#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The job carries the request's context to the worker, which starts its span
# in it.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/fulfil.py"
s = open(p).read()
for a, b in [
    ("from flask import Flask, request\n",
     "from flask import Flask, request\nfrom opentelemetry import context, trace\n"),
    ("JOBS = queue.Queue()\n", "JOBS = queue.Queue()\ntracer = trace.get_tracer(\"fulfil\")\n"),
    ('''        job = JOBS.get()
        reserve_stock(job["order"])
        print_label(job["order"])
''', '''        job = JOBS.get()
        with tracer.start_as_current_span("fulfil order", context=job["ctx"]):
            reserve_stock(job["order"])
            print_label(job["order"])
'''),
('"order": request.get_json(silent=True) or {}}', '"order": request.get_json(silent=True) or {},\n           "ctx": context.get_current()}'),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(p, "w").write(s)
PY
