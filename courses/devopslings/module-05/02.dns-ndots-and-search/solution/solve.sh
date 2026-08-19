#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# ndots:5 means any name with fewer than five dots is tried against every
# search domain before it is tried as written. "api.internal" has one dot, so
# "api.internal.corp.internal" is queried first — and the corp.internal wildcard
# answers it with 10.70.0.99. Lowering the threshold to 1 makes a name with a
# dot in it be tried as written first, which is what everyone assumed was
# happening.
#
# /etc/resolv.conf is a bind mount in a container. `sed -i` writes a temp file
# and renames it over the target, and the rename fails on a mount point, so the
# edited content is written back in place instead.
tmp=$(mktemp)
sed 's/^options ndots:5$/options ndots:1/' /etc/resolv.conf > "$tmp"
cat "$tmp" > /etc/resolv.conf
rm -f "$tmp"
