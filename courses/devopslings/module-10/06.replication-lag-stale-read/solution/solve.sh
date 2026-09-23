#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two separate things: start the replica replaying again, and stop the order
# page from assuming the replica is current when it reads.
set -euo pipefail

export PGPASSWORD=devopslings
R() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }

# Today's incident: replay is paused, so the standby is serving the moment it
# was paused at and falling further behind with every commit.
R -c "SELECT pg_wal_replay_resume() WHERE pg_is_wal_replay_paused()" >/dev/null

cat > /work/app/checkout.sh <<'SH'
#!/usr/bin/env bash
# Checkout, and the order page the customer lands on immediately after.
#
# The page reads the replica, which is always some amount behind. It waits for
# the WAL position of its own write rather than for a duration: lag is a
# moving number, so any fixed sleep is correct only until it isn't.
set -euo pipefail
export PGPASSWORD=devopslings

primary() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
replica() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica    "$@"; }

ref="CO-$(date +%s)-$$"

id=$(primary -c "SET application_name = 'checkout'" \
             -c "INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
                 VALUES (1, 'placed', '$ref', 4999, now()) RETURNING id")
lsn=$(primary -c "SELECT pg_current_wal_insert_lsn()")
echo "checkout: placed $ref as order $id at $lsn"

# Bounded: a replica that stops again must not take the page down with it.
caught_up=no
deadline=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$(replica -c "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn")" = t ]; then
    caught_up=yes
    break
  fi
  sleep 0.2
done

if [ "$caught_up" = yes ]; then
  status=$(replica -c "SET application_name = 'order-page'" \
                   -c "SELECT status FROM orders WHERE reference = '$ref'")
else
  # The replica is further behind than this page is willing to wait. One read
  # on the primary is the right price for that; every read on the primary is
  # not.
  echo "order-page: replica behind past the deadline, falling back to the primary" >&2
  status=$(primary -c "SET application_name = 'order-page-fallback'" \
                   -c "SELECT status FROM orders WHERE reference = '$ref'")
fi

if [ -z "$status" ]; then
  echo "order-page: MISSING $ref"
  exit 1
fi
echo "order-page: $ref is $status"
SH
chmod +x /work/app/checkout.sh

install -d /work/answers
cat > /work/answers/replication-lag.md <<'MD'
# The order page that cannot find the order

# What the replica is doing with the WAL it is receiving. One word, the
# one pg_is_wal_replay_paused() is asking about.
replica-replay: paused

# The function on the replica that says how far replay has actually got,
# so lag can be a number rather than a feeling.
lag-position: pg_last_wal_replay_lsn()

# Sending every read to the primary makes the stale read go away. One
# line: why is that not the fix?
why-not-all-primary: it moves all the order-page read traffic back onto the primary and leaves the replica idle, so the stale read is paid for with the capacity the replica was there to provide
MD

echo "replay resumed, and checkout now waits for its own write to reach the replica"
