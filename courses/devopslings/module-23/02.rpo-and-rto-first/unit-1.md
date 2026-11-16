---
title: "RPO and RTO first"
---

## The situation

A colleague wants sign-off on a backup design. It is two sentences long: pg2
already copies everything, so that is the backup, and a nightly `pg_dump` is
the extra safety.

It names tools. It never says what they have to achieve. Two numbers decide
whether any backup design is good enough:

- **RPO**, the recovery point objective: how much recent data you can afford
  to lose, measured back in time from the failure.
- **RTO**, the recovery time objective: how long the service can be down,
  from the decision to recover to taking orders again.

Every number you need is in `/ha/dr/facts.txt`, measured on production.

## Your objectives

Fill in `/ha/answers/rpo-rto.txt`:

1. Your RPO and RTO, at or inside what the business asked for.
2. A method — `dump`, `basebackup+wal` or `replica` — and how often a full
   backup is taken.
3. For `basebackup+wal`, the `archive_timeout` you would set.

## What you're being graded on

The grader works out what your design can deliver, using the numbers in
`facts.txt`, and compares it with what you stated:

- **data lost**: everything since the last dump, or since the last archived
  WAL segment, whichever applies;
- **time to recover**: 15 minutes to decide, plus the restore, plus any WAL
  replay.

Both must be within your objectives, and your objectives within the
business's. The design must also survive last year's incident.

<details>
<summary>Hint 1 — the replica</summary>

pg2 lags pg1 by under a second, which sounds like an RPO of one second. Now
replay last year's incident: someone runs `DELETE FROM orders` with no
`WHERE`. How long until pg2 has deleted them too?

</details>

<details>
<summary>Hint 2 — the dump</summary>

A nightly dump loses everything since 02:00: up to 24 hours. To bring that
down to 15 minutes you would need a dump every 15 minutes, and one takes 50.
Then look at what restoring it costs against the RTO.

</details>

<details>
<summary>Hint 3 — base backup plus WAL</summary>

Two separate knobs. `archive_timeout` bounds the RPO: it forces the current
WAL segment out to the archive at least that often, even when it is not full.
How often you take a base backup bounds the RTO: a restore copies the last
base backup back and then replays every hour of WAL since, at 4 minutes an
hour.

</details>

<details>
<summary>Solution</summary>

```
rpo_minutes: 15
rto_minutes: 60

method: basebackup+wal
full_backup_every_hours: 4
archive_timeout_seconds: 300
```

The arithmetic:

- **data lost**: at most `archive_timeout`, 5 minutes. Within 15.
- **time to recover**: 15 to decide + 25 to copy the base backup + 4 × 4 = 16
  to replay up to four hours of WAL = 56 minutes. Within 60. A base backup
  every 6 hours would make it 64 and miss.

### Why the order matters

Starting from a tool, you can always argue the tool is fine: the replica is
nearly instant, the dump is nightly, both are "backups". Starting from the
numbers, each option either fits or does not, and the argument is over in two
lines of arithmetic.

The replica fails on a different axis from the dump. It is excellent against
a dead disk or a dead server, and useless against a mistake, because it
faithfully copies the mistake. A design has to say which failures it is for.

### What this does not cover

The 25 and 190 minutes are what a restore took *last quarter*. A restore you
have not timed recently is a guess, and databases grow. Lesson 5 makes you
measure one.

</details>
