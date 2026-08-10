#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The record was not wrong to exist, it was wrong about where the host is.
# The fix is to point it at the address the host actually holds so the preferred
# protocol also works. The stale on-link route for the old prefix is removed too
# because it turned a wrong answer into a hang rather than an instant failure.
# With no route the connect fails immediately and the client moves on, while an
# on-link route makes the kernel queue the packet waiting for a neighbour that
# never replies. Disabling IPv6 or deleting the AAAA record would also stop the
# stall while leaving the host unreachable when the client is v6-only.
# /etc/hosts is a bind mount here, so it has to be rewritten in place rather
# than replaced — `sed -i` renames a temp file over it and the rename fails.
sed 's|^fd00:dead:beef::99 |fd00:51ee:9000::10 |' /etc/hosts > /tmp/hosts.fixed
cat /tmp/hosts.fixed > /etc/hosts
ip -6 route del fd00:dead:beef::/64 dev eth0 2>/dev/null || true
