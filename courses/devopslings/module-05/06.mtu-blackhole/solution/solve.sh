#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# dropping icmp fragmentation-needed breaks path mtu discovery, and deleting
# this one rule is the fix rather than widening the tunnel which belongs to
# another team
# nft prints the rule back as `icmp code 4`, not by the name it was written
# with, so match the type instead.
handle=$(ip netns exec r1 nft -a list chain inet tunnel output \
         | grep 'destination-unreachable' \
         | sed -n 's/.*# handle \([0-9]*\)$/\1/p')
[ -n "$handle" ] && ip netns exec r1 nft delete rule inet tunnel output handle "$handle"

# flush this host's route cache so no stale path mtu is remembered
ip route flush cache

# this first upload is what makes the host learn the 1400-byte path mtu
curl -s -m 20 --data-binary @/root/artifact.bin \
     http://10.90.2.9:8080/upload >/dev/null 2>&1 || true

# 1400 is the smallest mtu on the path, and 1372 is the largest ping -M do -s
# payload that survives it, because the 8-byte icmp header and the 20-byte ip
# header take the other 28 bytes
install -d /root/answers
cat > /root/answers/mtu.md <<'ANS'
path_mtu: 1400
largest_df_payload: 1372
ANS
