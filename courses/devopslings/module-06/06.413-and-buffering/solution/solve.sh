#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Two directives, and neither of them is "off".
#
# client_max_body_size is raised to a number this endpoint actually needs
# rather than removed: 0 means unbounded, and an unbounded body is an unbounded
# amount of whatever is holding it.
#
# proxy_request_buffering off makes nginx forward the body as it arrives
# instead of spooling the whole thing to disk first. The origin then sees the
# upload while it is happening — at the cost of holding an upstream connection
# open for the length of a slow client's send, which is the trade this
# directive is.
cat > /etc/nginx/sites-available/uploads <<'CONF'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://172.32.0.11:8080;

        client_max_body_size 32m;
        proxy_request_buffering off;
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
cat > /root/answers/upload.md <<'ANS'
rejected_by: proxy
limit_bytes: 1048576
ANS
