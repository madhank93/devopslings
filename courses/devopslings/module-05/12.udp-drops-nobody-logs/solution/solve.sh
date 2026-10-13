#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# SO_RCVBUF is silently capped at net.core.rmem_max, so the collector's 8 MB
# request became 208 KB. Raise the ceiling persistently and at runtime, then
# restart the collector: the buffer is sized when its socket is created.

printf 'net.core.rmem_max = 8388608\n' > /etc/sysctl.d/60-udp-collector.conf
sysctl -q --load /etc/sysctl.d/60-udp-collector.conf
systemctl restart metrics-collector.service

for _ in $(seq 1 20); do
  curl -s -m 1 http://127.0.0.1:9102/ | grep -q collector_received_total && break
  sleep 0.5
done
