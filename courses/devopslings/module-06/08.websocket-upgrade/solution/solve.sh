#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The websocket route gets its own location, because everything it needs is
# wrong for ordinary traffic.
#
# HTTP/1.1 upstream, because Upgrade does not exist in HTTP/1.0. Upgrade and
# Connection forwarded explicitly, because they are hop-by-hop headers and a
# proxy consumes them rather than passing them on. And a read timeout long
# enough that a quiet socket is not mistaken for a dead upstream — on this
# location only, where "no data for a while" is normal.
cat > /etc/nginx/sites-available/live <<'CONF'
server {
    listen 80 default_server;
    server_name _;

    location /ws {
        proxy_pass http://172.32.0.11:8080;
        proxy_set_header Host $host;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        proxy_pass http://172.32.0.11:8080;
        proxy_set_header Host $host;

        # Ordinary traffic gets a deadline shorter than nginx's own default:
        # here a long silence from the upstream is a fault, not a feature.
        proxy_read_timeout 10s;
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
cat > /root/answers/ws.md <<'ANS'
handshake_code: 426
idle_limit_seconds: 60
ANS
