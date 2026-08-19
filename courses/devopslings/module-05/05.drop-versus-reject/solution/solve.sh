#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The two dependency rules are removed by handle, one at a time, so that the
# quarantine rule for 10.80.0.9 is left in place. `nft flush ruleset` would fix
# both symptoms and silently unquarantine a host that was blocked deliberately.
for addr in 10.80.0.5 10.80.0.6; do
  handle=$(nft -a list chain inet appfw output \
           | grep "daddr $addr" \
           | sed -n 's/.*# handle \([0-9]*\)$/\1/p')
  [ -n "$handle" ] && nft delete rule inet appfw output handle "$handle"
done

# drop sends nothing, so the client waits for its own timeout. reject answers,
# so the client is refused immediately. Same firewall, same intent, two very
# different failure reports.
install -d /root/answers
cat > /root/answers/blocked.md <<'ANS'
inventory: signature=timeout rule=drop
shipping: signature=refused rule=reject
ANS
