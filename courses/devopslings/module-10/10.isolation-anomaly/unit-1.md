---
title: "eight refunds went through and the order is down by one of them"
---

## The situation

Order `ADJ-1` is under dispute and the billing team's adjuster has been run
against it several times in the same minute. Each run takes 500 cents off.

```
/work/app/adjust-many.sh 8
```

Eight runs. One deduction. The total went from 100000 to 99500 and stayed
there.

Nothing errored. Nothing rolled back. No deadlock, no constraint violation,
nothing in the log. All eight transactions committed, and each one wrote a
total that was correct given what it had read.

The adjuster already wraps the read and the write in a single transaction,
which is the first thing anybody checks.

## Your objectives

- Work out how eight committed transactions can leave seven deductions missing
- Make the eight of them add up, without changing what one adjustment does
- Measure what your fix costs when eight of them arrive at once

## What you're being graded on

The grader runs one adjuster alone and requires it to take 100000 to 99500.
Then it runs eight at once, three times over, and requires the total to land on
96000 every time with every adjuster exiting cleanly — if your fix makes the
losing transaction fail, running it again is part of the fix. You also fill in
`/work/answers/isolation.md`, including a measured number for the cost.

<details>
<summary>Hint 1 — look at what each transaction actually saw</summary>

Run two by hand in two psql sessions, a few seconds apart, and watch:

```sql
-- session 1                          -- session 2
BEGIN;                                BEGIN;
SELECT total_cents FROM orders        SELECT total_cents FROM orders
 WHERE reference = 'ADJ-1';            WHERE reference = 'ADJ-1';
-- 100000                             -- 100000
UPDATE orders SET total_cents = 99500
 WHERE reference = 'ADJ-1';
COMMIT;
                                      UPDATE orders SET total_cents = 99500
                                       WHERE reference = 'ADJ-1';
                                      COMMIT;
```

Had session 2's `UPDATE` arrived before session 1's `COMMIT`, it would have
blocked on the row lock until that commit — the lock does its job. Either way
it writes 99500 over the top of 99500. Both transactions were
serialised on the write and the answer is still wrong, because the number
session 2 wrote was worked out from a read that happened before session 1
existed.

```sql
SHOW default_transaction_isolation;
```

</details>

<details>
<summary>Hint 2 — read committed does not promise the row will hold still</summary>

Under `READ COMMITTED` — Postgres's default — each *statement* sees rows as
they were committed when that statement began. Nothing revisits an earlier
`SELECT` and nothing checks, at commit time, whether anything it read has
changed since. The transaction is atomic, and atomic is not the same property
as isolated.

That leaves three ways out, and they are genuinely different choices:

- **Lock the row when you read it.** `SELECT … FOR UPDATE` holds the row for
  the rest of the transaction, so the next adjuster blocks on the read and
  re-reads the committed total when it gets through.
- **Raise the isolation level.** Under `REPEATABLE READ`, the second
  transaction is refused with `could not serialize access due to concurrent
  update` and its work is thrown away. That is only a fix if something runs it
  again.
- **Stop reading it out to the client.** `UPDATE orders SET total_cents =
  total_cents - 500` computes inside the statement, against the row version the
  statement locks. There is no window because there is no round trip.

</details>

<details>
<summary>Hint 3 — the cost is the point, so measure it</summary>

`/work/app/adjust-many.sh 8` prints the wall time. Take a reading now, take one
after the change, and take one with a different fix if you want to see the
shape of it. Eight adjusters against one row, each holding it for 200ms:

- serialised on a row lock, the run costs roughly eight times one adjuster —
  every worker succeeds on its first attempt and spends its time waiting
- refused and retried, the run costs more than that and rises faster — the
  *n*th adjuster is refused *n−1* times before it lands, and every refusal
  throws away work already done

Neither is free, and which one you want depends on how contended the row is and
how expensive the work inside the transaction is. That is the decision the
number is for.

</details>

<details>
<summary>Solution</summary>

```bash
SELECT total_cents AS t FROM orders WHERE reference = '$ref' FOR UPDATE \gset
```

One clause. The row is locked at read time, the second adjuster waits there
instead of racing ahead with a figure that is about to be wrong, and when it
gets through it reads the committed total.

Measured on the sandbox, eight adjusters against one row:

```
broken           ~200ms   one deduction landed
FOR UPDATE      ~1700ms   all eight landed, no retries
REPEATABLE READ ~2700ms   all eight landed, attempts 1,2,3,4,5,6,7,8
```

The broken version was fast because it was not doing the work.

### The part worth remembering

**Atomicity is not isolation, and a transaction gives you the first by
default.** "It's all in one transaction" answers a different question from the
one being asked. The adjuster was atomic throughout — every run either applied
fully or not at all. What it lacked was any guarantee that what it read was
still true when it wrote.

**Read committed is a per-statement snapshot.** Each statement sees a fresh
view of committed data; nothing ties the view a `SELECT` had to the row a later
`UPDATE` touches, and nothing validates at commit. This is the default nearly
everywhere and it is the right default — it just means a read-modify-write
across a round trip is unsafe unless you say so.

**The lost update is invisible from inside.** No error, no conflict, no log
line. Every transaction committed and each was internally consistent. The only
way to see it is to check the arithmetic from outside, which is why this class
of bug is normally found by a customer and not by monitoring.

**Pick the mechanism by the contention, and measure it.** A row lock makes the
losers wait, which is cheap when the transaction is short and ruinous when it
is long — it is the same queueing that turned a blocked migration into a
table-wide outage in lock-contention. A serialization failure makes the losers
repeat work, which is cheap when conflicts are rare and quadratic when they are
not. Doing the arithmetic in the `UPDATE` avoids both and is not always
available, because real adjustments call out to things the database cannot.

**`SELECT … FOR UPDATE` is not a substitute for thinking about order.** Take
row locks in a consistent order across every writer, or the fix for this lesson
becomes the bug from deadlock-detected.

</details>
