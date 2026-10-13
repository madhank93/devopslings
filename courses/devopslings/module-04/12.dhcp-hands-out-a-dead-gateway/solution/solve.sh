#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# A leftover snippet sets the router option again after 10-lan2.conf, and
# dnsmasq keeps the last value it reads. Remove it, restart the server so the
# offer changes, then make web3 renew so its lease does.

rm -f /etc/lan-dhcp/conf.d/50-core-migration.conf
systemctl restart lan-dhcp.service
ip netns exec web3 dhcpcd -4 -n eth0

for _ in $(seq 1 20); do
  ip netns exec web3 ip route show default | grep -q 'via 10.60.0.1 ' && break
  sleep 0.5
done
