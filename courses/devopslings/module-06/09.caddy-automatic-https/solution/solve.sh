#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The certificate stops being a file and becomes a thing the server obtains.
#
# acme_ca points at the internal CA's directory; with no tls directive naming a
# keypair, Caddy manages the certificate for every site name it serves —
# obtaining it on first need and renewing it well before expiry, without anyone
# editing this file again.
cat > /etc/caddy/site.caddyfile <<'CFG'
{
    admin off
    acme_ca https://acme.internal:9443/acme/local/directory
}

web.internal {
    reverse_proxy 172.32.0.11:8080
}
CFG

caddy validate --config /etc/caddy/site.caddyfile --adapter caddyfile >/dev/null 2>&1
systemctl restart caddy-site.service

for _ in $(seq 1 60); do
  curl -s -m 3 https://web.internal/health 2>/dev/null | grep -q ok && break
  sleep 1
done

install -d /root/answers
cat > /root/answers/acme.md <<'ANS'
acme_directory: https://acme.internal:9443/acme/local/directory
cert_lifetime_hours: 12
ANS
