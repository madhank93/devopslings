---
title: "Replay: GitHub, October 2018"
---

## The situation

On 21 October 2018, maintenance work cut the link between GitHub's US East
Coast hub and its primary East Coast data center for 43 seconds. That was
long enough for the database orchestrator to decide the primary was gone.
It promoted a replica on the West Coast, and the applications followed it.
The East Coast primary had already accepted writes that the West Coast never
received. After the promotion, the West Coast accepted writes of its own.

Failing over took seconds. Getting back to normal took just over 24 hours.
Each side now had writes the other lacked, so neither database could simply
be made a copy of the other without losing some customer's data.

The replay here does the same thing at small scale. pg2 was promoted while
pg1 was cut off, and pg1 kept taking orders until the app moved. The app now
writes to pg2. Both servers handed out order ids from the same point, so
the same id can mean two different orders.

## Your objectives

1. In `/ha/answers/github-2018.txt`, count the orders only pg1 has, the
   orders only pg2 has, and the ids both servers used for different orders.
2. Write `/ha/failback.sh`, run from ops. Afterwards pg1 is the primary, the
   app uses it, every order either server took is on pg1 exactly once, and
   pg2 streams from pg1 again.

## What you're being graded on

First the three counts. Then the grader replays the partition from the
start, so your script always gets the same divergence, whatever you did
while exploring. It runs `/ha/failback.sh` while customers keep placing orders through www,
and checks pg1 order by order, using each order's reference. Every order a
customer was told succeeded, before or during the failback, has to be on
pg1. Then it places a new order through www and expects pg2 to be streaming
from pg1 with every order.

## Try it yourself

```
psql -h pg1 -c "select id, reference from orders order by id desc limit 5"
psql -h pg2 -c "select id, reference from orders order by id desc limit 5"
curl -s http://www/db
```

<details>
<summary>Hint 1 — what makes two rows the same order</summary>

An id alone does not identify an order here. After the split, pg1 and pg2
both gave out the ids that came next in the same sequence. Id 5012 on pg1
and id 5012 on pg2 can be two different customers. Compare
`(id, reference)` pairs. A pair present on both servers is an order from
before the split. Any other pair exists on one side only.

```
psql -h pg1 -tAXc "select id || '|' || reference from orders" | sort > /tmp/pg1
psql -h pg2 -tAXc "select id || '|' || reference from orders" | sort > /tmp/pg2
comm -23 /tmp/pg1 /tmp/pg2 | wc -l
```

</details>

<details>
<summary>Hint 2 — the order the failback has to follow</summary>

1. Stop pg2 from taking writes before copying anything from it. Otherwise
   an order placed during the copy is lost.
2. Copy the orders only pg2 has onto pg1, letting pg1 give each one a new
   id. Copying the old id either fails or overwrites a different order.
3. Point the app at pg1.
4. pg2 now has a history of its own, so it cannot start following pg1
   again. Rebuild it from pg1:
   `touch /ha/pg2/reclone; docker restart devopslings-ha-pg2`.

</details>

<details>
<summary>Solution</summary>

```
#!/bin/bash
set -euo pipefail
psql -h pg2 -qtAX -c "ALTER SYSTEM SET default_transaction_read_only = on" -c "SELECT pg_reload_conf()"
psql -h pg2 -qtAX -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                      WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()" >/dev/null

psql -h pg1 -qtAX -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS failback_import (id bigint, reference text, placed_at timestamptz)" -c "TRUNCATE failback_import"
psql -h pg2 -qtAX -v ON_ERROR_STOP=1 -c "\copy (SELECT id, reference, placed_at FROM orders) TO STDOUT" \
  | psql -h pg1 -qtAX -v ON_ERROR_STOP=1 -c "\copy failback_import FROM STDIN"
psql -h pg1 -qtAX -v ON_ERROR_STOP=1 \
  -c "INSERT INTO orders (reference, placed_at)
      SELECT i.reference, i.placed_at FROM failback_import i
      WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.id = i.id AND o.reference = i.reference)
      ORDER BY i.id" \
  -c "DROP TABLE failback_import"

sed -i 's/host=pg2/host=pg1/' /ha/app.env

mkdir -p /ha/pg2 && touch /ha/pg2/reclone
docker restart devopslings-ha-pg2 >/dev/null
for _ in $(seq 120); do
  [ "$(psql -h pg1 -qtAXc "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'")" = 1 ] && exit 0
  sleep 1
done
exit 1
```

### Why failing back is the hard direction

Failover makes a decision: this side is now the truth. It works best when
it does not look back. Failback cannot avoid looking back, because it has
to merge two histories that each accepted writes. That cannot be done
mechanically for every table. Orders can be merged by giving them new ids,
because nothing else refers to their old ids here. GitHub's data was not
that simple. They restored the East Coast clusters from backups, let them
catch up with the West Coast, and failed back to them. The writes stranded
on the old East Coast primaries were set aside and reconciled separately
afterwards, from the logs.

Among GitHub's follow-ups was configuring the orchestrator not to promote a
primary across regions, so a short partition could no longer split the
writes between coasts. The lesson for any failover design is the question
that was not asked in advance: once this has fired, how do we get back?

Source: GitHub's "October 21 post-incident analysis", 30 October 2018.

</details>
