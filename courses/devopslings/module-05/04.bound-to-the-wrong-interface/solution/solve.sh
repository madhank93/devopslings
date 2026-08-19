#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# 127.0.0.1 is not a restrictive setting on a real address, it is a different
# address entirely — the loopback interface, which no packet from another
# machine can ever arrive on. Nothing downstream of the socket can compensate.
# Binding 0.0.0.0 would fix the symptom and publish the service on the outside
# network at the same time, so the bind moves to exactly one address: the box's
# address on the lab network.
sed -i 's|--bind 127.0.0.1|--bind 172.31.0.10|' /etc/systemd/system/svc-orders.service
systemctl daemon-reload
systemctl restart svc-orders.service

for _ in $(seq 1 20); do
  curl -s -m 1 http://172.31.0.10:8080/ 2>/dev/null | grep -q orders-canonical-2026 && break
  sleep 0.5
done
