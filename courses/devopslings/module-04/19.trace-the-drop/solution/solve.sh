#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Every apps->db flow jumps through baseline_cross_zone before apps_to_db, and
# its dev-server range 5000-5999 contains 5432. Trace one packet to find it,
# record it, then return postgres from the baseline before the range drop, in
# the boot file, and reload.

ip netns exec fw2 nft add chain inet fw2 trace_pre '{ type filter hook prerouting priority -350; }'
ip netns exec fw2 nft add rule inet fw2 trace_pre ip saddr 10.92.1.30 tcp dport 5432 meta nftrace set 1
ip netns exec fw2 timeout 6 nft -a monitor trace > /root/trace.out 2>&1 &
sleep 1
ip netns exec apps nc -w2 10.92.2.10 5432 >/dev/null 2>&1 || true
wait || true

verdict=$(grep 'verdict drop' /root/trace.out | grep -v 'policy' | head -1)
chain=$(printf '%s\n' "$verdict" | sed -n 's/.*inet fw2 \([a-z_]*\) rule .*/\1/p')
handle=$(printf '%s\n' "$verdict" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
printf 'chain: %s\nhandle: %s\n' "$chain" "$handle" > /root/answers/trace.md

sed -i 's/^\([[:space:]]*\)tcp dport 5000-5999 counter drop$/\1ip daddr 10.92.2.10 tcp dport 5432 return\n&/' /etc/fw2/ruleset.nft
systemctl reload fw2-firewall.service
