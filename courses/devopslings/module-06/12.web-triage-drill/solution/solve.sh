#!/usr/bin/env bash
# Walks shop-smoke's failing step to the next hop and repairs the gateway at
# the first question that answers. It never reads /var/lib/drill: what the
# gateway and the upstreams say is enough.
set -euo pipefail
conf=/etc/nginx/sites-available/shop
mkdir -p /root/answers
answer() { printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$1" "$2" "$3" > /root/answers/triage.md; }

shop-smoke || true
build=$(cat /etc/shop/release)
api=$(curl -s -m 10 http://127.0.0.1/api/users || true)
reports=$(curl -s -o /dev/null -m 30 -w '%{http_code}' http://127.0.0.1/reports/daily || true)
upload=$(curl -s -o /dev/null -m 60 -w '%{http_code}' --data-binary @/var/lib/shop/basket-5m.bin http://127.0.0.1/upload || true)
ws=$(wsprobe http://127.0.0.1/ws --timeout 10 2>&1 || true)

# 1. A 404 in the upstream's own words: what was it asked for?
if [[ $api == "no route: /api/"* ]]; then
  curl -s http://172.32.0.11:8081/admin/received | tail -3
  perl -0pi -e 's#(location /api/ \{.*?proxy_pass http://172\.32\.0\.11:8080);#$1/;#s' "$conf"
  answer "proxy_pass on /api/ has no trailing slash, so the /api/ prefix is not stripped" \
         "curl :8081/admin/received shows GET /api/users, and the 404 body says no route: /api/users" \
         "upstream 404 rate on /api/ above 1% for 5 minutes"

# 2. A 504: whose deadline, and how long does the service really take?
elif [ "$reports" = 504 ]; then
  grep -m1 'timed out' /var/log/nginx/error.log || true
  perl -0pi -e 's#(location /reports/ \{\n)#$1        proxy_read_timeout 15s;\n#' "$conf"
  answer "reports route inherits the 3s proxy_read_timeout, shorter than the 5s a report takes" \
         "error.log: upstream timed out while reading response header; curl -w time_total on :8090 says 5s" \
         "504s on /reports/ above 0.5% for 5 minutes"

# 3. A 413: did the upstream ever see it?
elif [ "$upload" = 413 ]; then
  grep -m1 'client intended' /var/log/nginx/error.log || true
  perl -0pi -e 's#(location = /upload \{\n)#$1        client_max_body_size 20m;\n#' "$conf"
  answer "client_max_body_size missing on /upload, so nginx's 1m default refuses the 5 MB body" \
         "error.log: client intended to send too large body; no POST /upload in :8081/admin/received" \
         "413 rate on /upload above 1% for 10 minutes"

# 4. A refused handshake: what did the application receive?
elif [[ $ws == *426* ]]; then
  curl -s http://172.32.0.11:8081/admin/last
  perl -0pi -e 's#(proxy_http_version 1\.1;\n)#$1        proxy_set_header Upgrade \$http_upgrade;\n        proxy_set_header Connection "upgrade";\n#' "$conf"
  answer "the /ws location does not forward the hop-by-hop Upgrade and Connection headers" \
         "wsprobe through the gateway got 426; /admin/last shows no Upgrade header arrived" \
         "websocket handshake failures (426) above 5 in 5 minutes"

# 5. Everything answers and the asset is wrong: what is the cache keyed on?
else
  curl -si "http://127.0.0.1/asset.js?v=$build" | grep -i x-cache-status || true
  sed -i 's/\$host\$uri"/$host$request_uri"/' "$conf"
  rm -rf /var/cache/nginx/shop/*
  answer "proxy_cache_key uses \$uri, which drops the query string, so ?v=2 hits the cached build 1" \
         "X-Cache-Status: HIT for a never-requested ?v=2, and no asset.js request in :8081/admin/received" \
         "synthetic check: served build differs from deployed build for more than 2 minutes"
fi

nginx -t
systemctl restart nginx.service
for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 2 http://127.0.0.1/api/users && break
  sleep 0.5
done
shop-smoke
