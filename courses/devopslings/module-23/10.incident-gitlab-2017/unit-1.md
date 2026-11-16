---
title: "Replay: GitLab, January 2017"
---

## The situation

On the evening of 31 January 2017, GitLab.com's secondary database had
fallen behind its primary, and an engineer was trying to resync it. Tired,
late at night, and in the wrong terminal, he ran `rm -rf` on the primary's
data directory instead. He stopped it within seconds. About 300 GB was gone.

GitLab had five ways of getting that data back. As their own post-mortem
put it, none of them was working reliably or had been set up at all. The
nightly `pg_dump` had been producing near-empty files for some time: a
version mismatch made it fail, and the emails reporting the failure were
being rejected. Disk snapshots had never been enabled for the database
servers. Replication was the thing that had broken in the first place.
What saved them was an LVM snapshot that an engineer happened to take by
hand six hours earlier. Restoring it took around 18 hours, and six hours of
issues, merge requests, comments and new accounts were lost.

The shop here has the same five methods. Each of them is failing right now,
and the verification job that is supposed to notice is `exit 0`.

## Your objectives

Write `/ha/dr/verify-backups.sh`. For each method in `/ha/dr/backups.txt`
that is not working, it prints one line:

```
FAIL <method>: <why>
```

with `<method>` one of `dumps`, `snapshots`, `wal-archive`, `replica`,
`offsite`. It exits 0 only when all five are working.

## What you're being graded on

The grader first repairs all five methods and runs your job: it must exit 0
and print no `FAIL` line. Then, one method at a time, it breaks exactly that
method in the way it is broken now, runs your job, and repairs it again.
Each time, the job must exit non-zero and name that method, and only that
one.

"Working" means the method could give the data back today, not that the job
behind it ran.

## Try it yourself

```
cat /ha/dr/backups.txt
ls -la /ha/backups/dumps /ha/backups/snapshots
gunzip -c "$(ls /ha/backups/dumps/*.sql.gz | sort | tail -1)" | head
psql -x -c "select * from pg_stat_archiver"
psql -c "select application_name, state, replay_lsn, pg_current_wal_lsn() from pg_stat_replication"
(set -a; . /ha/backups/offsite.env; restic snapshots)
```

<details>
<summary>Hint 1 — what "working" means for each method</summary>

Ask of each one: if pg1 were deleted now, would this give the data back?

- **dumps** — the newest dump opens, and it is a whole dump. `pg_dump`
  writes `-- PostgreSQL database dump complete` as its last line; a file
  that decompresses to nothing does not have it.
- **snapshots** — there is one from the last 24 hours. An old one is a
  backup of a database that no longer exists.
- **offsite** — the repository has a recent snapshot in it. A repository
  that exists and answers is not a backup.

</details>

<details>
<summary>Hint 2 — the archiver keeps score</summary>

`pg_stat_archiver` counts since its statistics were last reset, so
`failed_count` stays above zero long after the archiver has recovered. What
tells you how it is doing now is which happened last:
`last_failed_time` or `last_archived_time`.

</details>

<details>
<summary>Hint 3 — streaming is not replaying</summary>

pg2 can be connected and receiving WAL while applying none of it. On pg1,
`pg_stat_replication` shows how far pg2 has replayed (`replay_lsn`) against
pg1's own position, and `pg_wal_lsn_diff` turns that into bytes. On pg2,
`pg_is_wal_replay_paused()` says whether replay has been stopped.

</details>

<details>
<summary>Solution</summary>

```
#!/bin/bash
B=/ha/backups
rc=0
fail() { echo "FAIL $1: $2"; rc=1; }

newest=$(ls -1 "$B"/dumps/shop-*.sql.gz 2>/dev/null | sort | tail -1)
if [ -z "$newest" ]; then fail dumps "no dump files"
elif [ -z "$(find "$newest" -mmin -1500)" ]; then fail dumps "newest dump $newest is over a day old"
elif ! gunzip -c "$newest" 2>/dev/null | grep -q 'PostgreSQL database dump complete'; then
  fail dumps "newest dump $newest is not a complete pg_dump"
fi

if [ -z "$(find "$B/snapshots" -mindepth 1 -maxdepth 1 -type d -mmin -1440 2>/dev/null)" ]; then
  fail snapshots "no snapshot in the last 24 hours"
fi

state=$(psql -h pg1 -tAX -c "SELECT current_setting('archive_mode') || ' ' ||
  CASE WHEN last_failed_time > coalesce(last_archived_time, '-infinity') THEN 'failing' ELSE 'ok' END
  FROM pg_stat_archiver" 2>/dev/null)
case $state in
  "on ok") ;;
  "") fail wal-archive "cannot read pg_stat_archiver on pg1" ;;
  *) fail wal-archive "archive_mode/archiver: $state" ;;
esac

lag=$(psql -h pg1 -tAX -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
  FROM pg_stat_replication WHERE application_name = 'pg2' AND state = 'streaming'" 2>/dev/null)
paused=$(psql -h pg2 -tAX -c "SELECT pg_is_wal_replay_paused()" 2>/dev/null)
if [ -z "$lag" ]; then fail replica "pg2 is not streaming from pg1"
elif [ "$paused" != f ] || [ "${lag%.*}" -gt 1048576 ]; then
  fail replica "pg2 is ${lag%.*} bytes behind pg1 (replay paused: ${paused:-unknown})"
fi

recent=$( (set -a; . "$B/offsite.env"; set +a; restic snapshots --json 2>/dev/null) \
  | jq -r '[.[] | select(.time > (now - 93600 | todate))] | length' 2>/dev/null)
[ "${recent:-0}" -gt 0 ] || fail offsite "no snapshot in the offsite repository from the last 26 hours"

exit $rc
```

### Why every method was broken and nobody knew

Each of GitLab's methods had a job that ran on schedule, and a job running
is what everyone watched. The dump job ran every night and wrote a file
every night. The failure email existed too; it just never arrived. Nothing
in that setup ever asked the question that matters: could this copy give
the data back?

A verification job answers that question for each method, and it has two
ways to fail. If it checks too little, it passes the empty dump. If it
alarms on a healthy system, people learn to ignore it, and then it passes
everything. The grader tests both directions for that reason.

This job is still not proof. The strongest check is the one from lesson 3:
restore the newest copy into an empty server and count the rows. A job
like this one is the cheap check you run every hour. The restore is the
expensive one you run every week.

Among GitLab's follow-ups was making someone responsible for testing that
backups restore, and fixing the alerting so a failed backup could not go
unnoticed again.

Source: GitLab's "Postmortem of database outage of January 31", 10 February
2017.

</details>
