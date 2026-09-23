#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Neither job is wrong. They take the same six rows in two different orders,
# so each can end up holding a row the other is about to ask for. Give them
# one order and the cycle cannot form.
set -euo pipefail

cat > /work/app/settle.sh <<'SH'
#!/usr/bin/env bash
# The two nightly passes over the settlement batch.
#
# Both walk the same six orders, and both take them in id order. That is not
# a preference: two transactions that acquire the same row locks in the same
# sequence can only ever queue behind one another, never form a cycle. The
# audit pass wanted newest first and does not get it — the output order of a
# batch job is worth less than the guarantee.
set -euo pipefail
export PGPASSWORD=devopslings
mode=${1:?usage: settle.sh reconcile|audit}
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

case "$mode" in
  reconcile) status="reconciled" ;;
  audit)     status="audited" ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac

ids=$(P -c "SELECT id FROM orders WHERE reference LIKE 'BATCH-%' ORDER BY id")

{
  echo "BEGIN;"
  for id in $ids; do
    echo "UPDATE orders SET status = '$status' WHERE id = $id;"
    # Per-row work: pull the invoice, write the ledger line.
    echo "SELECT pg_sleep(0.05);"
  done
  echo "COMMIT;"
} | P >/dev/null

echo "$mode: stamped $(printf '%s\n' $ids | wc -l | tr -d ' ') orders $status"
SH
chmod +x /work/app/settle.sh

install -d /work/answers
cat > /work/answers/deadlock.md <<'MD'
# Two jobs, one batch

# Postgres did not wait the cycle out. What did it do, and to which of
# the two transactions?
what-postgres-did: it picked one of the two as the victim, aborted it and rolled its whole transaction back, leaving the other to finish

# Both jobs walk the same six rows. Name the two columns they sort by —
# they are not the same column, and that is the bug.
the-two-orders: reconcile sorts by id ascending and audit sorts by placed_at descending, which over this batch is the exact reverse

# One line: why does catching the error and retrying the transaction not
# make this go away?
why-not-retry: the two jobs still take the rows in opposite orders, so the same cycle forms again on the next overlap — the retry only decides who pays for it, after the server has already waited out deadlock_timeout and thrown a transaction's work away
MD

echo "both passes now walk the batch in id order"
