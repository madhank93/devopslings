---
title: "The backup nobody has restored"
---

## The situation

`/ha/backups/backup.sh` dumps the shop database every night as `backup`, a
read-only role, and gzips the result. It has exited 0 every night since it
was written. The monitoring watches for a non-zero exit, so nobody has ever
been paged about it.

Nobody has ever restored one either.

## Your objectives

1. Restore `/ha/backups/shop.sql.gz` into an empty server and compare it with
   pg1. `scratchdb fresh` gives you one on `localhost:5433`.
2. Fix whatever stops the backup from being complete.
3. Make `backup.sh` exit non-zero when the dump fails, so the monitoring that
   already exists would notice.

## What you're being graded on

Two runs of your `backup.sh`:

- with everything up, it must exit 0, and its file, restored into a fresh
  empty Postgres, must match pg1 row for row in `customers`, `orders` and
  `refunds`;
- with the `shop` database refusing connections, it must exit non-zero.

The grader puts the last good backup back afterwards.

## Try it yourself

```
scratchdb fresh
gunzip -c /ha/backups/shop.sql.gz | psql -h localhost -p 5433 -d postgres
psql -h localhost -p 5433 -d postgres -c '\dt'
ls -l /ha/backups/shop.sql.gz
```

<details>
<summary>Hint 1 — what is in the file</summary>

`gunzip -c /ha/backups/shop.sql.gz | head` shows you. A file of a few dozen
bytes is a gzip header around nothing. Run the `pg_dump` line from the script
by yourself, with the same user and password, and without the pipe.

</details>

<details>
<summary>Hint 2 — why it exits 0</summary>

The exit status of a pipeline is the exit status of its *last* command. Here
that is `gzip`, which successfully compressed an empty stream. `pg_dump`'s
failure went to stderr, which a cron job sends to an inbox nobody reads.

`set -o pipefail` makes a pipeline fail if any stage fails. It does not stop
the script by itself — that is `set -e`.

</details>

<details>
<summary>Hint 3 — the privilege</summary>

The backup role was given `SELECT ON ALL TABLES` when the shop had two
tables. `ALL TABLES` means the tables that existed when the `GRANT` ran.
`refunds` came later. Since Postgres 14 the predefined role
`pg_read_all_data` grants read on every table, including future ones.

</details>

<details>
<summary>Solution</summary>

```
psql -c "GRANT pg_read_all_data TO backup"
```

and at the top of `backup.sh`:

```
set -euo pipefail
```

### What was wrong

`pg_dump` takes an `ACCESS SHARE` lock on every table it is going to dump
before it writes anything. Locking `refunds` needs `SELECT` on it, the backup
role did not have it, and `pg_dump` exited 1 at the first table with an empty
output. `gzip` compressed nothing into 20 bytes and exited 0. The job printed
"backup written".

Two separate faults, and either one alone would have been survivable: a
missing grant that fails loudly gets fixed the next morning, and a silent
pipeline over a job that never fails does no harm. Together they produce a
backup that has been empty since the day `refunds` was created.

### The only real test

The exit code tells you the job ran. The file size tells you something was
written. Only a restore into an empty server, followed by a comparison,
tells you the backup is a backup. Schedule it: a restore test that runs
every night and pages on mismatch catches this class of failure the day it
starts, not the day you need the data.

Using the `postgres` superuser for backups also makes this go away, and it is
why so many backup jobs run as superuser. A dedicated role with
`pg_read_all_data` cannot write, drop or change anything, which matters when
the backup host's credentials leak — see lesson 8.

</details>
