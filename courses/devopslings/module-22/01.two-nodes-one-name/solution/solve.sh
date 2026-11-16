#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Both servers in the pool, each with a health check. 'check' is what lets
# HAProxy notice a dead server: inter 1s fall 2 takes it out within about two
# seconds, rise 2 puts it back after two passing checks. Runs in ops.
set -euo pipefail

cat > /ha/haproxy.cfg <<'CFG'
frontend www
    bind :80
    default_backend app

backend app
    balance roundrobin
    option httpchk GET /health
    server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2
    server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2
CFG
sleep 3
