#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Name the span after the route template; the id stays on the span as order.id.
set -euo pipefail
sed -i 's|start_as_current_span(f"GET /orders/{order_id}"|start_as_current_span("GET /orders/{id}"|' /obs/apps/checkout.py
grep -q 'start_as_current_span("GET /orders/{id}"' /obs/apps/checkout.py
