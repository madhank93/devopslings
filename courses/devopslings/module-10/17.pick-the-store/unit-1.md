---
title: "four workloads, one store each"
---

## The situation

Four workloads, four stores to choose. Every one of them could be made to work
in the Postgres you already run, which is why the question is not "can it" —
it is what each workload actually demands, and which store is the one that
gives it.

The cases are in `reqs/`. Write a store and a deciding constraint for each into
`answers/verdict.md`:

```
case-1: store=? because=?
case-2: store=? because=?
case-3: store=? because=?
case-4: store=? because=?
```

`store` is one of `postgres`, `redis`, `timeseries`, `objectstore`. `because`
is one of `accesspattern`, `consistency`, `durability`, `cardinality`.

A store may be right more than once. A store may be right none of the times.

Two of these cases have the same shape — a number over time, aggregated over a
range — and different answers. Telling them apart is most of the exercise.

## What you're being graded on

Four correct stores and four correct constraints. The constraint has to be the
one that actually decides — the one that would still decide it if everything
else in the case changed. "It scales better" is not a token and is not a
reason.

## The four questions to ask of any workload

**What does a read ask for?** A single row by key, a range scanned in order, an
aggregate over a window, or a whole object by name. This is the one that
usually decides, and it is the one people skip because they start from the
write side.

**What must be true across two writes?** If two rows have to land together, or
a read right after a write has to see it, you need a store that offers it. Most
do not, and the ones that do not are not "eventually consistent enough" — they
have no transaction to put the pair in.

**What happens if the store is lost?** Not "is that bad" — everything is bad.
Can the system recompute it, or is this the only copy? Being allowed to lose
data is a *capability*: it buys you the fastest store in the list.

**How many distinct values does the key have?** A metrics store keeps a series
per distinct combination of labels and holds them all in memory. A relational
store keeps rows and indexes them. The first falls over at a cardinality the
second does not notice.

<details>
<summary>Hint 1 — start from the read, not the write</summary>

Write volume tells you how big the store has to be. The read tells you what
kind of store it has to be.

Case 4 never asks for one sample. Every query is an aggregate over a time
range, and the retention policy drops a whole day at once. That is a store that
can keep samples in time order, compress them in blocks, and delete a block
without touching an index.

Case 1 never asks for a range. It is one key, one integer, sixty thousand times
a second, and the key is dead an hour later.

Case 2 asks for a balance immediately after the write that changed it.

Case 3 asks for one customer out of 200,000, interactively.

Four different reads. Write them down before you pick anything.

</details>

<details>
<summary>Hint 2 — the case that says what you may lose</summary>

One case spends a paragraph telling you that losing the whole store costs
nothing. That paragraph is not colour. It is the constraint.

An in-memory store is the fastest thing on the list because it does not wait
for a disk. You can only take that trade when the data is derived — when the
system can recompute it or simply start again. Rate-limit counters for the
current minute are exactly that: lose them and every client gets a fresh
allowance, which is a bad minute, not an incident.

Take the same store for the ledger and the trade is a company-ending one for
the same reason.

So the token for case 1 is not `accesspattern`, even though the access pattern
is a perfect fit for a key-value store. Point lookups by key are also what
Postgres does all day. The line that decides is the one that says you are
allowed to lose it.

</details>

<details>
<summary>Hint 3 — count the series</summary>

Cases 3 and 4 are both "a latency or a reading, over time, aggregated over a
range". One goes in the metrics store and one does not.

A metrics store keeps one series per distinct combination of label values, in
memory, indexed. Case 4: 5,000 devices × 40 sensors = 200,000 series, and the
case tells you both are bounded. Case 3: 200,000 customers × 30 endpoints is
6 million *before* the histogram buckets that a p99 needs — and staging already
fell over at two million.

Cardinality is a property of the labels, not of the volume. Case 3 has *fewer*
events than case 4 by a factor of fifty and is the one that cannot go in the
metrics store.

The fix is not a bigger metrics server. It is to stop treating a
high-cardinality dimension as a label: keep the events as rows, index them by
customer and time, and compute the percentile at query time.

</details>

<details>
<summary>Solution</summary>

```
case-1: store=redis        because=durability
case-2: store=postgres     because=consistency
case-3: store=postgres     because=cardinality
case-4: store=timeseries   because=accesspattern
```

**Case 1 — rate limiter.** A committed write to Postgres waits for a disk
flush, and the budget for the whole check is a millisecond at 60,000 a second.
Redis is the answer because the case grants permission for it: the data is
derived and losing it costs one fresh allowance per client. The access pattern
also fits, but it fits Postgres too — durability is the constraint that
separates them.

**Case 2 — ledger.** Two rows that must both land, and a read straight after
that must see them. Append-only and modest volume make the other three stores
sound plausible; none of them gives you a transaction around the pair. Not a
throughput decision and not a durability one — all four are durable.

**Case 3 — per-customer SLO.** Same shape as case 4 and a fiftieth of the
volume. It is not a metrics workload, because customer id is a
high-cardinality dimension and a metrics store keeps a series per combination.
Rows in Postgres, partitioned by day, indexed on (customer, time).

**Case 4 — device fleet.** 200,000 samples a second, bounded tags, never
updated, never read individually, dropped a day at a time. That is what a
time-series store is built for: time-ordered blocks, column compression, and a
retention drop that unlinks a chunk instead of deleting rows.

### The part worth remembering

**The access pattern decides more often than the volume does.** "How much data"
sizes a store; "what does a read ask for" chooses one. A team that starts from
volume ends up with the store that can hold the data and cannot answer the
question.

**Postgres is the right answer more often than it is exciting.** It was right
twice here, once for a workload that everybody's instinct sends to a metrics
system. The general-purpose store you already run, already back up, and already
know how to restore has an enormous advantage that does not appear on any
comparison table.

**Being allowed to lose data is a capability, not a defect.** It is what lets
you skip the disk. Ask of every dataset whether it is derived or authoritative,
because the derived ones can go somewhere very fast and the authoritative ones
cannot — and the mistake that hurts is only ever in one direction.

**Cardinality is the failure nobody predicts.** It arrives as a one-line
change — add a label — and the metrics server that has been fine for two years
runs out of memory. Count the distinct combinations before adding a dimension,
not after, and treat anything with a user, customer, request or session id in
it as unbounded.

**Every store you add is a store you operate.** Four stores is four backup
procedures, four upgrade paths, four sets of failure modes and four things to
be woken up by. A workload that merely *runs better* somewhere else is not
enough of a reason. A workload the current store genuinely cannot serve —
because of the access pattern, the consistency it needs, the durability it does
not, or the cardinality it carries — is.

</details>
