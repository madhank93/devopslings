#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# p75 of each Navigation Timing phase: render (loadEventEnd - responseEnd) is
# most of the page load. Inside it, the render-blocking script with the largest
# p75 duration is the culprit; the beacon with a longer duration starts after
# the load event, so nothing waits for it.
set -euo pipefail
python3 - <<'PY'
import csv, math, statistics

def p75(xs):
    xs = sorted(xs)
    return xs[math.ceil(0.75 * len(xs)) - 1]

nav = list(csv.DictReader(open("/obs/rum/navigation.csv")))
res = list(csv.DictReader(open("/obs/rum/resources.csv")))
render = p75([float(r["loadEventEnd"]) - float(r["responseEnd"]) for r in nav])
server = p75([float(r["server_ms"]) for r in csv.DictReader(open("/obs/rum/server.csv"))])
blocking = {}
for r in res:
    if r["renderBlockingStatus"] == "blocking":
        blocking.setdefault(r["name"], []).append(float(r["duration"]))
culprit = max(blocking, key=lambda u: p75(blocking[u]))
open("/obs/answers/rum.txt", "w").write(f"""where: render
where_ms: {render:.0f}
culprit: {culprit}
server_ms: {server:.0f}
rum_sees: network time (DNS, TCP and TLS handshakes, round trips on mobile), the browser parsing and running JavaScript and rendering, and third-party scripts that block the page
instrument: real user monitoring in the browser: the OpenTelemetry web SDK or web-vitals reporting Navigation Timing, Resource Timing and LCP/INP from every page view, with the traceparent of the HTML request so a slow view links to its server trace
""")
print(open("/obs/answers/rum.txt").read())
PY
