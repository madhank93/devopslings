#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# checkout uses the same propagator as the services it calls.
set -euo pipefail
sed -i 's|OTEL_PROPAGATORS="b3multi"|OTEL_PROPAGATORS="tracecontext,baggage"|' /obs/apps/checkout.py
grep -q 'OTEL_PROPAGATORS="tracecontext,baggage"' /obs/apps/checkout.py
