#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Autovacuum was never broken. It was running the whole time and finding that
# none of the dead rows were removable, because an open transaction might
# still need to see the versions they replaced. Close that transaction and the
# same autovacuum reclaims everything.
set -euo pipefail
export PGPASSWORD=devopslings
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

# Who is holding the horizon, and how far back.
P -c "SELECT pid, application_name, state, backend_xmin,
             now() - xact_start AS open_for
        FROM pg_stat_activity
       WHERE datname = 'shop' AND backend_xmin IS NOT NULL
       ORDER BY xact_start" >/dev/null

P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
       WHERE datname = 'shop' AND pid <> pg_backend_pid()
         AND backend_type = 'client backend' AND backend_xmin IS NOT NULL" >/dev/null

# Plain VACUUM, not VACUUM FULL. The file stays the size it is; the pages in
# it go back on the free space map and the next restock pass writes into them
# instead of extending the table. No lock anybody notices.
P -c "VACUUM (ANALYZE) inventory" >/dev/null

install -d /work/answers
cat > /work/answers/bloat.md <<'MD'
# Ten times the data, none of it inserted

# What is stopping autovacuum reclaiming the dead rows. Name the state
# the session is in, and the pg_stat_activity column that shows how far
# back it is holding the horizon.
what-held-it: a session sitting idle in transaction since Tuesday with a repeatable-read snapshot still open — backend_xmin on its pg_stat_activity row is the oldest transaction id it still needs to see, and nothing newer than that may be removed

# VACUUM FULL would hand the disk space straight back. One line: why is
# it the wrong instrument on a table that is being served?
why-not-vacuum-full: it rewrites the whole table under an ACCESS EXCLUSIVE lock, so every reader and every restock pass queues behind it for the duration, and it needs room for a second full copy on disk while it runs

# After a plain VACUUM the file on disk is still exactly as big. One
# line: what did that VACUUM achieve, then?
what-vacuum-achieved: it put the dead row versions' space back on the free space map, so the next passes write into the existing pages instead of extending the file — the table stops growing even though it does not shrink
MD

echo "stock-report terminated and inventory vacuumed in place"
