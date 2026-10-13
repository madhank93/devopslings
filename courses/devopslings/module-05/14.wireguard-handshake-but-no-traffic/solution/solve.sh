#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# WireGuard only encrypts a packet for a peer whose AllowedIPs contain the
# destination, and wg-quick routes exactly those prefixes into the tunnel. The
# datacenter peer was allowed only its tunnel address, so add the subnet behind
# it and restart wg-quick to rebuild the interface and its routes.

sed -i 's|^AllowedIPs = 10.86.0.2/32$|AllowedIPs = 10.86.0.2/32, 10.87.0.0/24|' /etc/wireguard/wg0.conf
systemctl restart wg-quick@wg0.service

for _ in $(seq 1 20); do
  curl -s -m 2 http://10.87.0.10:8080/ | grep -q dc-app-answers-2026 && break
  sleep 0.5
done
