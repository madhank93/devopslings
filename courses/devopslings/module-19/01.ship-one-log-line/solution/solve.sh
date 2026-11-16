#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Push the decline as it was written, at the time it happened, into the stream
# {service="payments", level="error"}. Everything unique to the event (order,
# customer, message, time) stays in the line.
set -euo pipefail
oid=$(cat /obs/run/declined-order)
line=$(grep -F "\"$oid\"" /obs/logs/payments.log)
ns=$(jq -r '.ts' <<<"$line" | xargs -I{} date -d {} +%s%3N)000000

jq -n --arg ts "$ns" --arg line "$line" \
  '{streams: [{stream: {service: "payments", level: "error"}, values: [[$ts, $line]]}]}' |
  curl -sf -H 'Content-Type: application/json' --data-binary @- http://loki:3100/loki/api/v1/push

printf '{service="payments", level="error"} |= "%s"\n' "$oid" > /obs/queries/declined.logql
cat > /obs/answers/ship-one-log-line.txt <<'TXT'
labels: service, level
line: ts, order_id, customer, msg
TXT
