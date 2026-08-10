#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The request was translated by DNAT from 203.0.113.10:80 to 10.88.0.5:8080,
# but the reply was not translated back. Since the reply never passes through
# the box, it cannot be un-translated by conntrack. Masquerading the hairpinned
# traffic replaces the client's source address (10.88.0.6) with the bridge
# address (10.88.0.1), which forces the reply to travel back through the box.
# There, conntrack rewrites it to come from 203.0.113.10:80 as the client expects.
# The cost is that the service now logs 10.88.0.1 instead of the real client address,
# which is the standard trade-off and worth stating explicitly.
nft add rule ip pubnat post ip saddr 10.88.0.0/24 ip daddr 10.88.0.5 tcp dport 8080 masquerade
