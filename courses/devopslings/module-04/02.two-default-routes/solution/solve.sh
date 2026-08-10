#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Two default routes do not share traffic because equal prefix lengths are
# broken by metric, and the lower metric takes everything. A per-network route
# is more specific than either default, so each upstream's client is now
# reached through its own uplink. The route for network A is added too even
# though A already worked by accident, so that changing a metric later cannot
# silently move it.

ip route add 10.10.0.0/16 via 192.168.10.1 dev up-a
ip route add 10.20.0.0/16 via 192.168.20.1 dev up-b
