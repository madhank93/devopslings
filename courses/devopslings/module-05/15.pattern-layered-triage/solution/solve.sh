#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The fault is drawn at random, so this cannot be a list of commands: it is the
# ladder the lesson teaches, walked in order, stopping at the first rung that
# answers. Every rung below the fault passes, and every rung above it fails for
# a reason that is not its own — which is why order is the whole technique.
set -euo pipefail

cause=""
layer=""

tcp_open() {
  timeout 5 bash -c 'exec 3<>/dev/tcp/10.94.1.9/8443' 2>/dev/null
}

cert_ok() {
  echo | timeout 10 openssl s_client -connect 10.94.1.9:8443 \
    -servername api.partner.internal -verify_hostname api.partner.internal \
    -CAfile /etc/pki/api/ca.crt 2>/dev/null | grep -q 'Verify return code: 0 (ok)'
}

# ---- layer 2: does the frame have somewhere to go? ---------------------
real=$(ip netns exec gw cat /sys/class/net/gw-box/address 2>/dev/null || true)
have=$(ip -o neigh show 10.94.0.2 dev to-gw 2>/dev/null | sed -n 's/.*lladdr \([0-9a-f:]*\).*/\1/p' | head -1)
if [ -n "$have" ] && [ -n "$real" ] && [ "$have" != "$real" ]; then
  # Delete rather than correct it: the entry was static, and the reason to
  # remove it is that this address should be learned, not configured.
  ip neigh del 10.94.0.2 dev to-gw
  cause=arp
  layer=2
fi

# ---- layer 3: does the packet have a next hop? -------------------------
if [ -z "$cause" ] && ! ip route get 10.94.1.9 2>/dev/null | head -1 | grep -q 'via 10.94.0.2'; then
  ip route replace 10.94.1.0/24 via 10.94.0.2 dev to-gw
  cause=route
  layer=3
fi

# ---- layer 4: is the port open along the path? -------------------------
if [ -z "$cause" ] && ! tcp_open; then
  ip netns exec gw nft delete table inet drill 2>/dev/null || true
  cause=firewall
  layer=4
fi

# ---- layer 7: does the name answer, and answer correctly? --------------
if [ -z "$cause" ] && [ "$(dig +short api.partner.internal @127.0.0.1 2>/dev/null | tail -1)" != "10.94.1.9" ]; then
  sed -i 's#^address=/api.partner.internal/.*#address=/api.partner.internal/10.94.1.9#' /etc/dnsmasq.d/partner.conf
  systemctl restart dnsmasq.service
  cause=dns
  layer=7
fi

# ---- layer 6: is the certificate for the name being asked for? ---------
if [ -z "$cause" ] && ! cert_ok; then
  sed -i -e 's#^cert=.*#cert=/etc/pki/api/api.crt#' \
         -e 's#^key=.*#key=/etc/pki/api/api.key#' /etc/api/tls.conf
  systemctl restart payments-api.service
  cause=tls
  layer=6
fi

if [ -z "$cause" ]; then
  echo "no rung of the ladder failed, and the scenario seeds a fault on every run"
  exit 1
fi

# The service and the resolver both need a moment after a restart, and the
# neighbour entry needs one ARP exchange.
for _ in $(seq 1 20); do
  curl -sS -m 3 https://api.partner.internal:8443/health 2>/dev/null \
    | grep -q 'payments-api ok' && break
  sleep 0.5
done

install -d /root/answers
printf 'layer: %s\ncause: %s\n' "$layer" "$cause" > /root/answers/triage.md
echo "repaired at layer $layer: $cause"
