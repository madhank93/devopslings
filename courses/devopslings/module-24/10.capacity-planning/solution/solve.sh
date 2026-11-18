#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Little's Law per resource: in use = peak rate x mean time each request
# holds it. Web nodes are sized from busy cores at 70%; the provider's
# concurrency limit is the first wall, and no number of web nodes moves it.
set -euo pipefail
python3 - <<'PY' > /ha/answers/capacity.txt
import csv, math, statistics
rows = list(csv.DictReader(open("/ha/sre/capacity/loadtest.csv")))
m = {c: statistics.fmean(float(r[c]) for r in rows) for c in ("cpu_ms", "db_ms", "provider_ms")}
h, peak = 0.7, 600
busy = {c: peak * v / 1000 for c, v in m.items()}
at = {"web_cpu": h * 8 / (m["cpu_ms"] / 1000), "db_connections": h * 90 / (m["db_ms"] / 1000),
      "payment_concurrency": h * 80 / (m["provider_ms"] / 1000)}
first = min(at, key=at.get)
print(f"headroom: 70%\npeak: {peak}")
print(f"resource: web_cpu | {m['cpu_ms']:.1f} ms | {busy['cpu_ms']:.2f} cores | {math.ceil(busy['cpu_ms'] / (4 * h))} nodes")
print(f"resource: db_connections | {m['db_ms']:.1f} ms | {busy['db_ms']:.1f} connections | {max(90, math.ceil(busy['db_ms'] / h))} connections")
print(f"resource: payment_concurrency | {m['provider_ms']:.1f} ms | {busy['provider_ms']:.1f} calls | {math.ceil(busy['provider_ms'] / h)} calls")
print(f"saturates_first: {first}\nsaturates_at: {at[first]:.0f}")
PY
