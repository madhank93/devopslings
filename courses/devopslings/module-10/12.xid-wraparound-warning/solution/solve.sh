#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The horizon was pinned by a prepared transaction: a two-phase commit whose
# coordinator never came back for the second phase. It has no backend, so it
# appears in no session view and no timeout reaches it, and it survives
# restarts by design.
set -euo pipefail
export PGPASSWORD=devopslings
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

P -c "SELECT gid, transaction, prepared, owner FROM pg_prepared_xacts ORDER BY prepared" >/dev/null

# Roll it back rather than commit it: this half of the settlement was never
# confirmed to the other side, and committing one arm of a distributed
# transaction on a guess is how the two systems stop agreeing. In a real
# incident that decision is made with whoever owns the coordinator.
for gid in $(P -c "SELECT gid FROM pg_prepared_xacts"); do
  P -c "ROLLBACK PREPARED '$gid'" >/dev/null
done

# Now the freeze can move. Autovacuum would get here on its own; this is the
# incident, so do not wait for it.
P -c "VACUUM (FREEZE, ANALYZE) ledger" >/dev/null

# And put back the setting that was never the problem but is still wrong: it
# bought nothing against wraparound, and it does mean ordinary dead rows on
# this table are nobody's job.
P -c "ALTER TABLE ledger RESET (autovacuum_enabled)" >/dev/null

install -d /work/answers
cat > /work/answers/wraparound.md <<'MD'
# The age that will not come down

# What is holding the transaction id horizon. There is no session for it
# and no lock — name the view that lists the thing, and what it is.
what-held-it: a prepared transaction, settlement-0091, listed in pg_prepared_xacts — a two-phase commit that was prepared and never committed or rolled back, so its xid is still live

# autovacuum_enabled was set to off on ledger months ago, and autovacuum
# has been running against it anyway. One line: why?
why-autovacuum-ran-anyway: anti-wraparound vacuums are forced once a table passes autovacuum_freeze_max_age and they ignore autovacuum_enabled entirely, because the alternative is the server running out of transaction ids

# Nobody fixed it and the age kept climbing. One line: what does Postgres
# do when it runs out of transaction ids to give out?
what-happens-at-the-limit: it refuses to accept any further write commands and has to be brought up in single-user mode to be vacuumed, so it is a full outage rather than a slow degradation
MD

echo "settlement-0091 rolled back, ledger frozen, age now $(P -c "SELECT age(relfrozenxid) FROM pg_class WHERE relname='ledger'")"
