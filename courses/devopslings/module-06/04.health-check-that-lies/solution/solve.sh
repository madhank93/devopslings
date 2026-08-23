#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Two changes, and the first one is the fault.
#
# /ready is the endpoint whose answer depends on the dependency; /health only
# ever proved the process was running. And the interval had to come down: at
# inter 10s fall 3 the check is correct and takes thirty seconds to act, which
# is thirty seconds of failed requests every time a node goes sick.
cat > /etc/haproxy/haproxy.cfg <<'CFG'
global
    log stdout format raw local0
    stats socket /run/haproxy/admin.sock mode 660 level admin
    daemon

defaults
    mode http
    timeout connect 3s
    timeout client 15s
    timeout server 15s

    option httpchk GET /ready
    default-server check inter 2s fall 2 rise 2

frontend gateway
    bind *:8000
    default_backend app

backend app
    server a 172.32.0.11:8080
    server b 172.32.0.11:8090
CFG

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1
systemctl reload haproxy.service

for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 2 http://127.0.0.1:8000/orders && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/healthcheck.md <<'ANS'
check_path: /ready
health_proves: liveness
ANS
