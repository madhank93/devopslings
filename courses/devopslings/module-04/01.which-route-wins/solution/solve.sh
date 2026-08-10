#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The kernel picks the most specific matching prefix, not the first line of
# ip route show and not the one with the best metric. A /24 beats a /16 for
# every address inside it, so the /16 was never consulted for 10.50.7.5.
# Deleting the /24 lets the /16 cover the whole partner network again.
# Repointing the /24 at 10.60.0.2 would also work but leaves a redundant
# route to go stale a second time.
ip route del 10.50.7.0/24 via 172.31.0.99 dev eth0
