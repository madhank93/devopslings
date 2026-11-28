#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# ledger's server span starts before checkout's client span that called it,
# by the same few seconds in every trace, while fulfil's nests: ledger's host
# clock is behind. Stepping that clock back to true (what `chronyc makestep`
# does on a real host) fixes every timestamp the host writes, spans included.
set -euo pipefail
tid=$(cat /obs/data/clock-skew.trace)
for _ in $(seq 1 15); do
  ms=$(curl -s "http://tempo:3200/api/traces/$tid" | python3 -c '
import json, sys
spans = {}
for b in json.load(sys.stdin).get("batches", []):
    svc = next(a["value"]["stringValue"] for a in b["resource"]["attributes"] if a["key"] == "service.name")
    for ss in b["scopeSpans"]:
        for s in ss["spans"]:
            spans[s["spanId"]] = dict(s, svc=svc)
for s in spans.values():
    p = spans.get(s.get("parentSpanId"))
    if s["svc"] == "ledger" and p and p["svc"] == "checkout":
        print(round((int(s["startTimeUnixNano"]) - int(p["startTimeUnixNano"])) / 1e6))
        break
' 2>/dev/null || true)
  [ -n "$ms" ] && break
  sleep 2
done
[ -n "$ms" ]
sed -i -e 's/^cause: ?.*/cause: ledger host clock is behind (clock skew)/' -e 's/^host: ?.*/host: ledger/' \
  -e "s/^offset_ms: ?.*/offset_ms: $ms/" /obs/answers/clock-skew.txt
touch /obs/hosts/ledger/makestep
