#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# FRR refuses to send or accept routes on an eBGP session with no policy
# (RFC 8212), which is why the session is up and empty. Give it policy in both
# directions: out, our public block and nothing else; in, what the provider
# sends. Then save, so frr.service loads the same config on restart.

vtysh -c 'configure terminal' \
      -c 'ip prefix-list OUR-PREFIXES seq 5 permit 198.51.100.0/24' \
      -c 'route-map TRANSIT-OUT permit 10' \
      -c ' match ip address prefix-list OUR-PREFIXES' \
      -c 'exit' \
      -c 'route-map TRANSIT-IN permit 10' \
      -c 'exit' \
      -c 'router bgp 65010' \
      -c 'address-family ipv4 unicast' \
      -c 'no redistribute connected' \
      -c 'network 198.51.100.0/24' \
      -c 'neighbor 10.83.0.2 route-map TRANSIT-OUT out' \
      -c 'neighbor 10.83.0.2 route-map TRANSIT-IN in' \
      -c 'end' \
      -c 'write memory'

for _ in $(seq 1 30); do
  ip route show 192.0.2.0/24 | grep -q 'proto bgp' && break
  sleep 1
done
