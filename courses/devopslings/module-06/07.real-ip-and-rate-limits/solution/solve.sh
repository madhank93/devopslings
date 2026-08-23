#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The limiter is told which single address is allowed to speak for other
# addresses, and nothing else. set_real_ip_from is a trust list, not a switch:
# with 127.0.0.1 on it, entries appended by the edge are believed and entries
# written by the client are not.
#
# real_ip_recursive on makes nginx walk the chain from the right, discarding
# trusted proxies, and stop at the first address that is not one of them. That
# address is the closest thing to the truth that exists — and a client that
# invents a chain only ever prepends to it.
cat > /etc/nginx/sites-available/tiers <<'CONF'
# the rate limiter, reachable only from this box
server {
    listen 127.0.0.1:8081;

    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    location / {
        limit_req zone=perip burst=2 nodelay;
        proxy_pass http://172.32.0.11:8080;
        add_header X-Limiter-Saw $remote_addr always;
    }
}

# the edge, where clients arrive
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
CONF

nginx -t >/dev/null 2>&1
systemctl reload nginx.service

for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 2 http://127.0.0.1/health && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/realip.md <<'ANS'
before_key: 127.0.0.1
xff_trust: rightmost-untrusted
ANS
