#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# OSPF neighbours must agree on hello and dead intervals; a hello carrying
# different timers is discarded, so the adjacency never starts. edge1 runs the
# defaults (10s/40s), so drop the core's overrides on to-edge1 and save the
# running config so frr.service loads the same thing on restart.

vtysh -c 'configure terminal' \
      -c 'interface to-edge1' \
      -c 'no ip ospf hello-interval' \
      -c 'no ip ospf dead-interval' \
      -c 'end' \
      -c 'write memory'

for _ in $(seq 1 30); do
  vtysh -c 'show ip ospf neighbor' | grep -q '^10\.80\.255\.2 .*Full' && break
  sleep 1
done
