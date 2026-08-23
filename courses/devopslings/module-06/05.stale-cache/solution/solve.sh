#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Two lines.
#
# $request_uri is the path *and* the query string, so a fingerprinted URL is
# its own cache entry again and a deploy is visible the moment it lands.
#
# The Vary the origin sends is the origin saying one stored copy is not enough
# for this response. Ignoring it is what served alice's profile to bob.
cat > /etc/nginx/sites-available/edge <<'CONF'
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://172.32.0.11:8080;
        proxy_cache edge;

        proxy_cache_key "$scheme$request_method$host$request_uri";

        proxy_cache_valid 200 60s;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
CONF

nginx -t >/dev/null 2>&1
systemctl reload nginx.service

# Everything stored while Vary was ignored is still stored wrong: the fix
# changes what happens next, not what is already on disk. One purge clears the
# poisoned entries. That is remediation for a corrupted cache, and not the same
# thing as purging on every deploy — which is the habit this lesson is against.
find /var/cache/nginx/edge -type f -delete 2>/dev/null || true

for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 2 http://127.0.0.1/asset.js && break
  sleep 0.5
done

install -d /root/answers
cat > /root/answers/cache.md <<'ANS'
key_missing: query
vary_header: X-User
ANS
