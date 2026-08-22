#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Two one-character changes.
#
# /api/: proxy_pass gains a URI part — a bare "/" — which makes nginx replace
# the matched prefix instead of forwarding the request URI untouched.
#
# /docs: the location gains a trailing slash, so the prefix that gets replaced
# includes the separator and the leftover no longer starts with one.
cat > /etc/nginx/sites-available/gateway <<'CONF'
server {
    listen 80 default_server;
    server_name _;

    location /api/ {
        proxy_pass http://172.32.0.11:8080/;
        proxy_set_header Host $host;
    }

    location /docs/ {
        proxy_pass http://172.32.0.11:8080/pages/;
        proxy_set_header Host $host;
    }
}
CONF

nginx -t >/dev/null 2>&1
systemctl reload nginx.service

for _ in $(seq 1 20); do
  curl -s -m 2 http://127.0.0.1/api/users 2>/dev/null | grep -q alice && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/proxy.md <<'ANS'
api_before: /api/users
docs_before: /pages//intro
ANS
