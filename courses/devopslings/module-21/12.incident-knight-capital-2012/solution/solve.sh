#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > preflight.sh <<'SH'
#!/usr/bin/env bash
# Pre-open gate: runs before SMARS is allowed to trade.
# Usage: ./preflight.sh FLEET_DIR
# Exit 0 only when every host in the inventory is running exactly the release
# build. Otherwise exit 1 and name each host that is not.
set -u
fleet=${1:?usage: preflight.sh FLEET_DIR}

if [ ! -s "$fleet/inventory" ]; then
  echo "REFUSE: no inventory at $fleet/inventory — nothing to check against"
  exit 1
fi

bad=0
while read -r host; do
  [ -n "$host" ] || continue
  if [ ! -d "$fleet/hosts/$host" ]; then
    echo "REFUSE $host: cannot inspect it"
    bad=1
  elif ! diff -r "$fleet/release" "$fleet/hosts/$host" >/dev/null 2>&1; then
    echo "REFUSE $host: does not match release/"
    bad=1
  fi
done < "$fleet/inventory"

[ "$bad" -eq 0 ] && echo "every host matches release/ — safe to trade"
exit "$bad"
SH
chmod +x preflight.sh

cat > answers/reconstruction.md <<'MD'
# One line per field.

divergent_host: smars-8

root_cause: The deploy never reached smars-8, so it still had the Power Peg code that the new RLP code was meant to replace, and the new code had repurposed the flag that used to activate Power Peg — so on that one server every flagged RLP order switched on Power Peg, which since 2005 could no longer tell when a parent order was filled and kept sending child orders.

rollback: Taking the new RLP code off the seven correct servers put the old Power Peg code back on them while orders still arrived with the flag set, so all eight servers then ran Power Peg and the response made the problem worse rather than containing it.
MD

echo "preflight.sh and answers/reconstruction.md written"
