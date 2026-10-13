"""The game day report: shop's counters and pricing's, per phase.

Run inside the checkout container after the load test. Prints for people;
the grader reads the `kv` lines.
"""

import json
import urllib.request


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


shop = get("http://localhost:8214/stats")
ledger = get("http://pricing:8214/stats")
PHASES = [("steady", "5% of connections reset"),
          ("rush", "2x traffic, pricing 1.5s/call"),
          ("outage", "pricing hung, 8s/call"),
          ("recovering", "pricing healthy again"),
          ("after", "pricing healthy (graded)")]

print("checkout, as shop counted it:")
print("  %-11s %-30s %6s %8s %8s %4s %4s %7s" % (
    "phase", "conditions", "orders", "pricing", "fallback", "404", "503", "slowest"))
for name, what in PHASES:
    p = shop["phases"].get(name, {})
    print("  %-11s %-30s %6d %8d %8d %4d %4d %6.1fs" % (
        name, what, p.get("checkouts", 0), p.get("from_pricing", 0), p.get("fallback", 0),
        p.get("not_found", 0), p.get("failed_503", 0), p.get("max_ms", 0) / 1000))
print()
print("shop's calls to pricing:")
print("  %-11s %6s %8s %8s %13s %15s" % (
    "phase", "calls", "timeouts", "resets", "pool refused", "breaker refused"))
for name, _ in PHASES:
    p = shop["phases"].get(name, {})
    print("  %-11s %6d %8d %8d %13d %15d" % (
        name, p.get("pricing_calls", 0), p.get("timeouts", 0), p.get("connect_errors", 0),
        p.get("pool_refused", 0), p.get("breaker_refused", 0)))
print("  breaker opened %d times" % shop["breaker_opens"])
print()
r = ledger["received"]
print("pricing, its own counters: received steady %d, rush %d, outage %d, after %d;"
      % (r["steady"], r["rush"], r["outage"], r["after"]))
print("  %d requests arrived again after pricing had answered them 404"
      % ledger["repeated_after_404"])
print()
print("browse: %d served, slowest handler %dms; recommendations failed on %d (%s),"
      % (shop["browse"], shop["browse_max_ms"], shop["recs_failed"], shop["recs_error"] or "-"))
print("  so those got bestsellers")
print()
steady = shop["phases"].get("steady", {})
print("kv steady_orders=%d" % steady.get("checkouts", 0))
print("kv steady_received=%d" % r["steady"])
print("kv breaker_opens=%d" % shop["breaker_opens"])
for name, _ in PHASES:
    p = shop["phases"].get(name, {})
    for k in ("failed_503", "timeouts", "pool_refused", "breaker_refused"):
        print("kv %s_%s=%d" % (name, k, p.get(k, 0)))
