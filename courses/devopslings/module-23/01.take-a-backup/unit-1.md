---
title: "Take a backup, then open it"
---

## The situation

The shop's database is backed up every night by a job that runs on pg1 and
writes a plain-SQL dump to `/ha/backups/shop.sql`. It has never failed. Nobody
has ever opened what it writes.

The shop has three tables that matter: `customers`, `orders` and `refunds`.

## Your objectives

1. Run the backup: `/ha/backups/nightly.sh`.
2. Open `/ha/backups/shop.sql` and find out, for each of the three tables,
   whether restoring this file would bring its rows back.
3. Record it in `/ha/answers/take-a-backup.txt`, `yes` or `no` per table.

## What you're being graded on

- `/ha/backups/shop.sql` exists and is a complete dump;
- every answer matches what is in the file.

The job's settings are drawn fresh each time the scenario starts, so the
answer is in the file, not in this page.

## Try it yourself

```
/ha/backups/nightly.sh
less /ha/backups/shop.sql
grep -n 'CREATE TABLE\|^COPY' /ha/backups/shop.sql
```

<details>
<summary>Hint 1 — how a plain dump is laid out</summary>

A plain-format dump is a SQL script. It creates each table with `CREATE
TABLE`, then loads its rows with a `COPY public.<table> (...) FROM stdin;`
line followed by one row per line, ending at a line holding only `\.`. Indexes,
constraints and sequence values come after the data.

</details>

<details>
<summary>Hint 2 — a table can be there and still be empty</summary>

Finding `CREATE TABLE refunds` tells you the table will exist after a restore.
It does not tell you it will have anything in it. Look for its `COPY` line.

</details>

<details>
<summary>Solution</summary>

```
/ha/backups/nightly.sh
grep '^COPY' /ha/backups/shop.sql
```

Two of the three tables have a `COPY` block. The third appears only as a
`CREATE TABLE`: the job runs `pg_dump --exclude-table-data=<table>`, which
keeps the table's definition and drops its rows. Restoring this backup gives you
that table, empty, and no error to tell you so.

### Why this matters

`--exclude-table-data` is a real and useful flag. It is how teams keep a
huge audit log or a cache table out of their nightly dump. Then someone adds
a pattern like `--exclude-table-data='*_log'` and a table called
`change_log` that the business depends on quietly stops being backed up.

A backup job's exit status says the job finished. It says nothing about what
the file contains. The only evidence of what a backup holds is the backup:
open it, or better, restore it and count — which is the next lesson but one.

</details>
