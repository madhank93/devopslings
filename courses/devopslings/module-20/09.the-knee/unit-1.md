---
title: "The ninth node made it slower"
---

## The situation

The ledger takes entries off a queue, converts each to US dollars, and adds it
to one balance row. Each node is a loop: fetch an entry (about 20ms), then
`post()` it. The code every node runs is `answers/ledger.py`:

```python
def post(entry):
    with ledger_lock:
        rate = fx_rate(entry["currency"])
        balance = store.get()
        store.put(balance + entry["amount"] * rate)
```

`store.py`, in the lesson's `files/`, is the shared part: the rates service
(about 5ms a call), the balance row, and `ledger_lock`, the lock on that row.
It is not yours to change.

Last quarter, four nodes kept up. Then the queue grew, someone added nodes,
and throughput stopped rising at around five and fell after that. The plan on
the table is to go to sixteen. Measure it first:

```
bash <lesson>/files/bench.sh answers/ledger.py 1 2 3 4 5 6 8 9 12
```

Each line is one run of 4 seconds: the node count, entries posted a second,
and how many cents the balance is off by.

## Why adding a node can make it slower

Two separate effects, and the Universal Scalability Law names both:

- **Contention.** Work that only one node can do at a time. However many nodes
  you add, the lock is held for a fixed time per entry, so throughput can never
  exceed `1 / (time the lock is held)`. Contention makes the curve flatten.
- **Coherency.** The cost of the nodes coordinating with each other, which
  grows with the number of nodes: each one that waits for the row is another
  one polling it, cache lines bouncing between cores, a lock manager walking a
  longer queue. Here, handing the lock on costs more the more nodes are
  waiting. Coherency is what makes the curve turn **down**.

The point where the curve bends is the knee. Past it, a new node adds a little
work and a lot of waiting, and the waiting slows everyone else.

The way out is not more nodes. It is a shorter time under the lock.

## Your objectives

1. Find the node count at which the original code posts the most entries a
   second, and write it in `answers/the-knee.txt`:

   ```
   peak_nodes=<n>
   ```

2. Change `answers/ledger.py` so that **nine** nodes (`NODES=9` in
   `sandboxes/chaos-stack/.env`) post well over the original peak, and the
   balance stays exact.

## What you're being graded on

The lesson's init measured the original code at each node count on your
machine. `peak_nodes` has to be the node count with the highest rate in that
run, or one within 7% of it. Then the check runs your `ledger.py` at `NODES`,
which must be 9 or fewer: it must post at least 1.4 times the original peak
with no cents lost.

<details>
<summary>Hint 1 — fewer nodes</summary>

Setting `NODES` to the peak gets you back to the peak, and no further. The
peak itself is set by how long each `post()` holds `ledger_lock`. Time how
long that is, and which of the three steps inside the lock are about the
balance.

</details>

<details>
<summary>Hint 2 — removing the lock</summary>

Without the lock, two nodes read the same balance, each adds its own entry,
and the second write erases the first. The bench shows it in the `lost`
column. The read and the write of the row have to stay together under the
lock. The rate lookup does not.

</details>

<details>
<summary>Solution</summary>

`answers/ledger.py`:

```python
def post(entry):
    # The rate lookup does not touch the balance, so it runs outside the lock;
    # only the read-modify-write of the row needs it.
    rate = fx_rate(entry["currency"])
    with ledger_lock:
        balance = store.get()
        store.put(balance + entry["amount"] * rate)
```

The original held the lock for the 5ms rates call, so the most the ledger
could ever post was about 200 a second, and the hand-off cost grew with every
node queued behind it. Moved out, the lock covers only the read and the write
of the row, which take microseconds, and nine nodes run close to nine times
one node's rate.

```
peak_nodes=4
```

(or 5: the measured peak on your machine.)

### Finding the critical section in real systems

- A database row lock held across an HTTP call to another service is the same
  bug: `BEGIN; SELECT ... FOR UPDATE;` then a call out, then `UPDATE`. Do the
  call before the transaction, or after it.
- A profile that shows most threads waiting on one lock, with the holder doing
  I/O, is the signature. Lock contention metrics (Postgres `pg_locks`, Java
  thread dumps, Go's mutex profile) name the lock.
- Contention you cannot remove can sometimes be split: per-account balances
  instead of one, or batching many entries into one write.

</details>
