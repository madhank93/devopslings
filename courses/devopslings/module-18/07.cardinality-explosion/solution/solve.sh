#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Label requests by route template again. The raw path put one series per
# order ID into every metric; the template answers the same per-endpoint
# questions with four values.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/shop.py"
s = open(p).read()
for bad, good in [
    ('"HTTP requests served, by path and status code.",\n    ["method", "path", "code"])',
     '"HTTP requests served, by route template and status code.",\n    ["method", "route", "code"])'),
    ('["path"], buckets=', '["route"], buckets='),
    ('''            # Label by the exact path requested, so a slow order can be found by its ID.
            path = self.path.split("?")[0]
            REQUESTS.labels("GET", path, str(code)).inc()
            LATENCY.labels(path).observe(time.time() - start)''',
     '''            REQUESTS.labels("GET", route, str(code)).inc()
            LATENCY.labels(route).observe(time.time() - start)'''),
]:
    assert bad in s, bad
    s = s.replace(bad, good)
open(p, "w").write(s)
PY
