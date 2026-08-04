#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/slow-services <<'SH'
#!/bin/bash
set -euo pipefail

# The log is JSON. A JSON parser knows which bytes are a field and which are
# text inside a string, which is the whole distinction the regex could not make:
#
#   .duration_ms       the record's own field, never one nested inside .upstream
#   > 500              a numeric comparison, not a digit pattern
#   .service           the field, whatever it contains — spaces included
#
# Field order stops mattering entirely, because nothing is anchored on position.
jq -r 'select(.duration_ms > 500) | .service' /srv/events/events.jsonl \
  | sort -u
SH
chmod 0755 /usr/local/bin/slow-services
