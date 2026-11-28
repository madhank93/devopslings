#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Reads the seeded cause from the code, as a reviewer who followed the
# evidence to the right file would, picks a slow trace as the exemplar before
# fixing, then fixes the code where the cause lives. It never reads
# /var/lib/devopslings/apm-triage-drill.
set -euo pipefail
python3 - <<'PY'
import json, re, time, urllib.parse, urllib.request

A = "/obs/apps"
src = {f: open(f"{A}/{f}.py").read() for f in ("checkout", "fulfil", "ledger")}
if "BoundedSemaphore(1)" in src["ledger"]:
    cause, svc, fix = "pool", "ledger", ("ledger", "BoundedSemaphore(1)", "BoundedSemaphore(16)")
elif "for sku in skus" in src["fulfil"]:
    cause, svc = "n-plus-one", "pricing"
    fix = ("fulfil", re.search(r"prices = \{\}\n.*?\n.*?\n", src["fulfil"], re.S).group(0),
           'prices = call(tracer, "GET", "http://ledger:8080/prices?skus=" + ",".join(skus))\n')
elif r"([a-z0-9]+\.?)*" in src["checkout"]:
    cause, svc, fix = "regex", "checkout", ("checkout", r'r"([a-z0-9]+\.?)*[a-z0-9]+@shop\.example"', r'r"[^@\s]+@[^@\s]+"')
elif "attempts=8" in src["checkout"]:
    cause, svc, fix = "retry-storm", "checkout", ("checkout", "timeout=0.02, attempts=8", "timeout=1.0, attempts=2")
else:
    cause, svc = "lock", "checkout"
    m = re.search(r"( *)with LEDGER:[^\n]*\n( *)(call\(tracer, \"POST\"[^\n]*\n)", src["checkout"])
    fix = ("checkout", m.group(0), m.group(1) + m.group(3))

for _ in range(60):
    now = int(time.time())
    q = urllib.parse.urlencode({"q": '{resource.service.name="checkout" && name="POST /checkout" && duration > 150ms}',
                                "start": now - 300, "end": now, "limit": 1})
    found = json.load(urllib.request.urlopen(f"http://tempo:3200/api/search?{q}", timeout=15)).get("traces")
    if found:
        ex = found[0]["traceID"]
        break
    time.sleep(3)
else:
    raise SystemExit("no checkout trace over 150ms in Tempo after 3 minutes")

f, old, new = fix
s = open(f"{A}/{f}.py").read()
assert old in s, (cause, old)
open(f"{A}/{f}.py", "w").write(s.replace(old, new))

evidence = {
    "n-plus-one": ("pricing -> ledger carries ten times the request rate of checkout -> pricing",
                   "GET /prices on ledger runs a dozen times per quote, each a few milliseconds",
                   "pricing's CPU is idle: the time is spent waiting on ledger, call after call"),
    "pool": ("pricing -> ledger and checkout -> ledger are both slow while ledger's own work is short",
             "ledger's server spans are slow at p99 and its request rate unchanged",
             "ledger's CPU is idle: requests wait for a connection, not for work"),
    "regex": ("every edge is fast; checkout's own time is what grew",
              "POST /checkout p99 grew while its client spans did not",
              "checkout's CPU is in re fullmatch, called from validate email"),
    "retry-storm": ("checkout -> pricing request rate is several times the order rate, with failures",
                    "pricing serves far more quotes than checkout takes orders",
                    "pricing's CPU is busy serving retries of quotes nobody is waiting for any more"),
    "lock": ("checkout -> ledger is fast per call, and checkout's time is outside every client span",
             "POST /checkout p99 grew with no slow downstream span",
             "checkout's CPU is idle: threads wait on a lock around the ledger call"),
}[cause]
open("/obs/answers/triage.md", "w").write(f"""cause: {cause}
service: {svc}
service_map: {evidence[0]}
spanmetrics: {evidence[1]}
exemplar: {ex}
profile: {evidence[2]}
detect: histogram_quantile(0.99, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{{service_name="checkout",span_name="POST /checkout"}}[1m])))
threshold: 150
""")
print(open("/obs/answers/triage.md").read())
PY
