#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# web2 gets weight 10 against web1's 90. The analysis compares the canary
# with the baseline from the same log, never with a fixed number: errors as
# a rate, latency as p95, each with a margin for noise.
set -euo pipefail
sed -i -E 's/^([[:space:]]*server web1 .*)$/\1 weight 90/; s/^([[:space:]]*server web2 .*)$/\1 weight 10/' /ha/haproxy.cfg
cat > /ha/sre/canary-analysis <<'PY'
#!/usr/bin/env python3
"""canary-analysis LOG: compare web2 (canary) with web1 (baseline). Exit 0 promote, 1 reject."""
import sys
from collections import defaultdict

seen = defaultdict(list)
for line in open(sys.argv[1]):
    f = line.split()
    seen[f[3].split("/")[-1]].append((int(f[5]), int(f[4].split("/")[4])))
base, canary = seen["web1"], seen["web2"]
if len(canary) < 50 or len(base) < 50:
    sys.exit(f"inconclusive: {len(canary)} canary and {len(base)} baseline requests")


def error_rate(xs):
    return sum(s >= 500 for s, _ in xs) / len(xs)


def p95(xs):
    t = sorted(ms for _, ms in xs)
    return t[int(len(t) * 0.95) - 1]


print(f"errors:  canary {error_rate(canary):.2%}  baseline {error_rate(base):.2%}")
print(f"p95:     canary {p95(canary)} ms  baseline {p95(base)} ms")
if error_rate(canary) > 2 * error_rate(base) + 0.01:
    print("reject: errors")
    sys.exit(1)
if p95(canary) > 2 * p95(base) + 50:
    print("reject: latency")
    sys.exit(1)
print("promote")
PY
chmod +x /ha/sre/canary-analysis
sleep 2
