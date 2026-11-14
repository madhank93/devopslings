#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The collector pauses ~20 ms per 1000 counters while ~8000/s keep arriving:
# ~160 datagrams at ~1.2 KB of kernel accounting each, ~200 KB. Ask for 512 KB
# so there is headroom; even a host ceiling of 212992 still yields 425984.
sed -i 's/^rcvbuf_bytes = .*/rcvbuf_bytes = 524288/' /etc/collector/collector.conf
systemctl restart metrics-collector.service

for _ in $(seq 1 20); do
  curl -s -m 1 http://127.0.0.1:9102/ | grep -q collector_received_total && break
  sleep 0.5
done
