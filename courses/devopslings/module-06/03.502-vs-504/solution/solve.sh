#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The 502 is at the far end: the orders backend was accepting connections and
# closing them without answering. Nothing on the proxy could have fixed it.
curl -s -X POST -m 5 'http://172.32.0.11:8091/admin/mode?value=normal' >/dev/null

# The 504 is at this end: the users report legitimately takes six seconds and
# the proxy was giving up at three. The longer deadline goes on that route
# only — raised at server level it would also mean a stalled orders backend
# holds a worker for fifteen seconds instead of three.
cat > /etc/nginx/sites-available/gateway <<'CONF'
server {
    listen 80 default_server;
    server_name _;

    proxy_connect_timeout 3s;
    proxy_read_timeout 3s;

    location /orders {
        proxy_pass http://172.32.0.11:8090;
    }

    location /users {
        proxy_pass http://172.32.0.11:8080;
        proxy_read_timeout 15s;
    }
}
CONF

nginx -t >/dev/null 2>&1
systemctl reload nginx.service

for _ in $(seq 1 20); do
  curl -s -m 3 http://127.0.0.1/orders 2>/dev/null | grep -q 1001 && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/gateway.md <<'ANS'
orders_cause: closed
users_cause: timeout
users_upstream_seconds: 6
ANS
