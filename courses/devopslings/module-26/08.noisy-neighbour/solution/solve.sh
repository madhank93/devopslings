#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Fair share across tenants: a burst queues behind its own tenant only, and
# takes whatever capacity the others are not using.
set -euo pipefail
sed -i 's/^scheduler: fifo$/scheduler: fair/' /obs/platform/runners.yml
mkdir -p /obs/answers
cat > /obs/answers/noisy-neighbour.txt <<'TXT'
chosen: fair share scheduling | each tenant's builds start in proportion to its share, so a burst queues behind itself and still uses every idle runner
rejected: more runners | the budget is 8, and a bigger pool only drains the same head-of-line queue faster; the next backfill is bigger
rejected: dedicated pools | runners reserved for data sit idle between backfills, and the backfill is limited to its slice when the pool is quiet
TXT
