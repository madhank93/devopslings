#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# the proxy has no route to the inside, so internal names have to skip it; curl
# matches NO_PROXY against the host in the URL, which is why the name is listed
# rather than the address it resolves to
grep -v -i -e '^http_proxy=' -e '^https_proxy=' -e '^no_proxy=' /etc/environment \
  > /tmp/env.new 2>/dev/null || true
cat /tmp/env.new > /etc/environment
rm -f /tmp/env.new
cat >> /etc/environment <<'ENV'
http_proxy=http://10.91.0.2:3128
HTTP_PROXY=http://10.91.0.2:3128
no_proxy=inventory.corp,localhost,127.0.0.1
NO_PROXY=inventory.corp,localhost,127.0.0.1
ENV

# a systemd service never reads /etc/environment, so the same settings have to
# reach it through the unit
install -d /etc/systemd/system/stock-sync.service.d
cat > /etc/systemd/system/stock-sync.service.d/proxy.conf <<'DROPIN'
[Service]
Environment=http_proxy=http://10.91.0.2:3128
Environment=HTTP_PROXY=http://10.91.0.2:3128
Environment=no_proxy=inventory.corp,localhost,127.0.0.1
Environment=NO_PROXY=inventory.corp,localhost,127.0.0.1
DROPIN

systemctl daemon-reload

install -d /root/answers
cat > /root/answers/proxy.md <<'ANS'
internal_via_proxy_status: 502
service_ignores: /etc/environment
ANS
