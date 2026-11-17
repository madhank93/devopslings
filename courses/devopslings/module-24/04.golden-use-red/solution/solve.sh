#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# RED over the window from the log; the hurting minute is the first minute
# whose p99 passes one second; USE picks the resource with a queue.
set -euo pipefail
read -r rate err p99 since < <(python3 - /ha/sre/shop-requests.log <<'PY'
import math, sys
from collections import defaultdict
win, per_min = [], defaultdict(list)
for l in open(sys.argv[1]):
    f = l.split()
    if f[-2].split("?")[0] not in ("/", "/cart", "/orders"):
        continue
    ta, st, ts = int(f[4].split("/")[4]), int(f[5]), f[1][13:21]
    per_min[ts[:5]].append(ta)
    if "10:15:00" <= ts <= "10:29:59":
        win.append((ta, st))
def p99(xs):
    xs = sorted(xs)
    return xs[max(0, math.ceil(.99 * len(xs)) - 1)]
since = min(m for m, xs in per_min.items() if p99(xs) > 1000)
print(f"{len(win) / 900:.3f}", f"{100 * sum(s >= 500 for _, s in win) / len(win):.2f}",
      p99([t for t, _ in win]), since)
PY
)
cat > /ha/answers/use-red.txt <<TXT
rate_per_second: $rate
error_percent: $err
p99_ms: $p99
customers_hurting_since: $since
saturated_resource: disk
mismatched_claims: A D
TXT
cat /ha/answers/use-red.txt
