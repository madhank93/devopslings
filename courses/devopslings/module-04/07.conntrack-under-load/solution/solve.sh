#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The fix is to decide the traffic does not need tracking, and that decision has
# to be made before an entry is allocated, which is what the raw hooks at
# priority -300 are for — a rule in a normal filter chain runs after conntrack
# has already done the work; both the output and prerouting hooks are needed
# because packets this box originates take the first and packets it forwards take
# the second; `notrack` is not a drop, the packets are delivered exactly as
# before and simply stop being remembered; lowering `nf_conntrack_udp_timeout`
# would shrink the damage without stopping the allocation, and raising
# `nf_conntrack_max` trades memory for time; and the existing entries are
# cleared so the effect is visible immediately rather than in five minutes.
nft add table ip rawtrack
nft 'add chain ip rawtrack out { type filter hook output priority -300 ; }'
nft 'add chain ip rawtrack pre { type filter hook prerouting priority -300 ; }'
nft add rule ip rawtrack out ip daddr 10.67.0.5 udp dport 9125 notrack
nft add rule ip rawtrack pre ip daddr 10.67.0.5 udp dport 9125 notrack
conntrack -D -p udp --dport 9125 >/dev/null 2>&1 || true
