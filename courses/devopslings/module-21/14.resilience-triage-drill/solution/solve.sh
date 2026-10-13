#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Reads the settings against what the module's lessons established — a timeout
# under the 3s budget and over pricing's slow-but-working 1.5s, a fallback, no
# retried 4xx, a breaker that trips on a run of failures, a bulkhead narrower
# than the 16 threads — and repairs the first one that is off. It never reads
# the scenario's state file.
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

env_val() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"\r' | xargs || true; }
set_val() {
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { $0 = k "=" v } { print }' .env > .env.new
  cat .env.new > .env && rm -f .env.new
}

tmo=$(env_val PRICING_TIMEOUT)
pool=$(env_val PRICING_POOL)
ron=$(env_val RETRY_ON)
thr=$(env_val BREAKER_THRESHOLD)

if [ -z "$(env_val FALLBACK_PRICE)" ]; then
  set_val FALLBACK_PRICE 39.99
  cause="FALLBACK_PRICE is empty, so every pricing call refused or failed fast became a 503 instead of a price"
  evidence="the report's 503 column: hundreds in the rush and outage rows, matching pool refused and breaker refused"
  detection="checkout 5xx rate > 1% for 1 minute"
elif printf ',%s,' "$ron" | grep -q ',4xx,'; then
  set_val RETRY_ON connect,5xx
  cause="RETRY_ON includes 4xx, so every 404 for a retired SKU was retried until attempts ran out"
  evidence="pricing's counter: requests that arrived again after it answered 404 is above 0"
  detection="pricing requests per checkout > 1.1, or any retry of a 404 > 0"
elif awk -v t="$tmo" 'BEGIN { exit !(t + 0 <= 0 || t + 0 >= 3) }'; then
  set_val PRICING_TIMEOUT 2
  cause="PRICING_TIMEOUT=$tmo is longer than pricing hung for, so it never fired and checkouts waited 8s"
  evidence="outage row: slowest checkout 8.0s, 0 timeouts, breaker opened 0 times"
  detection="checkout max latency > 3s, or p99 > 2s for 1 minute"
elif [ "$thr" = 0 ] || [ "$thr" -gt 10 ]; then
  set_val BREAKER_THRESHOLD 5
  cause="BREAKER_THRESHOLD=$thr is more failures in a row than the outage produced, so the breaker never opened"
  evidence="pricing received about 40 calls during the outage; breaker opened 0 times while timeouts climbed"
  detection="calls to pricing while its error rate > 50% for 30 seconds, with the breaker still closed"
elif [ "$pool" = 0 ] || [ "$pool" -ge 16 ]; then
  set_val PRICING_POOL 8
  cause="PRICING_POOL=$pool is as wide as shop's 16 threads, so the rush put every thread in a pricing call and browse starved"
  evidence="browse p95 in seconds while its handler took milliseconds; pool refused 0 in the rush"
  detection="browse p95 > 500ms, or worker threads busy > 90% for 1 minute"
else
  echo "no setting is off, and the scenario breaks one on every run" >&2
  exit 1
fi

printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" \
  > "$DEVOPSLINGS_ROOT/scratch/resilience-triage-drill/triage.md"
