#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One character. `^~` on the reports prefix tells nginx that if this is the
# longest matching prefix it should stop there and not try the regexes at all,
# which is the only way a plain prefix beats a regex that also matches.
set -euo pipefail

sed -i 's|^\( *\)location /api/v2/reports/ {|\1location ^~ /api/v2/reports/ {|' \
  /etc/nginx/sites-available/gateway
grep -n 'location' /etc/nginx/sites-available/gateway

nginx -t
systemctl reload nginx.service

install -d /root/answers
cat > /root/answers/gateway.md <<'MD'
# The gateway

# In the order the gateway applies them, what decides which route a
# request takes? Name the steps, first to last.
the-order: the host picks the server block via server_name, then the path picks the location — exact = match first, then the longest prefix marked ^~, then the regexes in file order, then the longest ordinary prefix — and only once a location has been chosen does anything look at the method or the headers, which is why a rule that depends on either lives inside the block rather than choosing it

# One line: the reports route is longer and more specific than the v2
# route, and it lost. Why?
why-the-longer-route-lost: the v2 block is a regex location and the reports block was an ordinary prefix, and nginx tries regexes before it falls back to the longest prefix, so length never entered into it — the prefix only wins if it is marked ^~

# One line: moving the reports block above the v2 block changed nothing.
# What in this file is order-dependent, and what is not?
what-order-affects: only the regex locations are tried in the order they appear; exact and prefix matches are chosen by what they match rather than by where they sit, so moving a prefix block around the file cannot change anything
MD

echo "reports route marked ^~"
