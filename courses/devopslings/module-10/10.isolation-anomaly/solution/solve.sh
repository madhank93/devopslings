#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Under read committed the SELECT sees the row as it was committed at that
# moment and nothing re-checks it later, so the figure the client is holding
# goes stale the instant another adjuster commits. Take the row lock at read
# time and the next adjuster waits for the new figure instead of overwriting
# it with an old one.
set -euo pipefail

cat > /work/app/adjust.sh <<'SH'
#!/usr/bin/env bash
# One adjustment against the order under dispute.
#
# FOR UPDATE is the whole fix. It locks the row for the rest of the
# transaction, so a second adjuster blocks on the read rather than racing
# ahead with a figure that is about to be wrong, and re-reads the committed
# total when it gets through.
set -euo pipefail
export PGPASSWORD=devopslings
amount=${1:-500}
ref=${2:-ADJ-1}

psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 >/dev/null <<SQL
BEGIN;
SELECT total_cents AS t FROM orders WHERE reference = '$ref' FOR UPDATE \gset
-- Working the new figure out: fees, tax, the partial-refund rules.
SELECT pg_sleep(0.2);
UPDATE orders SET total_cents = :t - $amount WHERE reference = '$ref';
COMMIT;
SQL
SH
chmod +x /work/app/adjust.sh

install -d /work/answers
cat > /work/answers/isolation.md <<'MD'
# Eight refunds, one deduction

# The isolation level the adjuster was running under while the
# deductions were going missing.
isolation-level: read committed

# What you changed so that two adjusters cannot both act on the same
# figure. Say which of the two shapes it is: one that makes the second
# transaction wait, or one that makes it fail and run again.
what-you-chose: SELECT ... FOR UPDATE, so the row lock is taken at read time and the second adjuster waits rather than being refused and retried

# Run eight adjusters at once and time it, before and after. One line:
# what does the fix you chose cost as contention rises, and why?
the-cost: about 1700ms for eight adjusters against roughly 200ms broken, because the row lock serialises them and the run now costs one worker's work times the number of workers queued behind it
MD

echo "adjuster now takes the row lock when it reads the total"
