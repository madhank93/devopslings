---
title: "the write came back ok and the read cannot find it"
---

## The situation

The profile store has three nodes, on ports 7001, 7002 and 7003. Nothing
replicates between them — they do not know about each other. The client is the
only thing that ever writes to them, and it decides how many nodes a write goes
to and how many a read asks.

```
/work/app/client.sh put user:1 alice
/work/app/client.sh get user:1
```

Support says profile edits sometimes do not stick: the save says it worked and
the page comes back with the old value. Refresh a few times and sometimes it
is right.

The ticket says a node needs restarting. Every node is up and answering.

```
cat /work/app/client.sh
```

## Your objectives

- A read must see the write that came immediately before it, every time
- A value written while all three nodes are up must survive losing any one of
  them
- The store must keep serving reads and writes with one of the three down

## What you're being graded on

Three rounds. With all three nodes up, fifteen writes each followed by a read
that must see it. Then, for each node in turn: fifteen values written with
everything up, that node stopped, and all fifteen read back. Then, again for
each node in turn: that node stopped, and fifteen write-then-read pairs that
must all succeed and all match. You also fill in `/work/answers/quorum.md` with
N, W and R and why the inequality between them is the one that matters.

<details>
<summary>Hint 1 — count the nodes a write lands on</summary>

Write something, then look at all three nodes directly:

```
/work/app/client.sh put user:7 carol
for p in 7001 7002 7003; do echo -n "$p: "; redis-cli -p $p get user:7; done
```

One node has it. Two do not, and never will — there is no replication to catch
them up later. So a read that asks a single node has a one in three chance of
asking the right one.

That is the whole bug, and "eventually consistent" is not what is happening
here: nothing converges, because nothing is propagating.

</details>

<details>
<summary>Hint 2 — the inequality</summary>

With N nodes, a write that waits for W acknowledgements and a read that waits
for R answers, the read is guaranteed to see the write if

```
R + W > N
```

Two subsets of a set of size N whose sizes add up to more than N cannot be
disjoint — there is no room. So the read set always contains at least one node
from the write set, and if the read takes the newest version it saw, it takes
the write's.

The client already does the second half: it compares versions across the nodes
that answered and returns the newest. It is the two numbers at the top that are
wrong.

Six combinations satisfy the inequality at N=3. Only one of them survives the
next hint.

</details>

<details>
<summary>Hint 3 — now lose a node</summary>

```
redis-cli -p 7002 shutdown nosave
```

With two nodes answering:

- `W=3` cannot be acknowledged. Every write fails.
- `R=3` cannot be answered. Every read fails.
- `W=1` puts the value on one node, so the next node to fail takes data with
  it.

What is left is the pair that makes R + W = 4 out of the two nodes that are
still there.

Bring it back with the same `redis-server` line the scenario used, or
`devopslings reset quorum-and-eventual-consistency`.

</details>

<details>
<summary>Solution</summary>

```bash
# /work/app/client.sh
N=3
W=2
R=2
```

Read-your-write holds with all three up, a value survives any single node's
loss, and the store still serves with one node gone.

### The part worth remembering

**R + W > N is a statement about sets, not about speed.** It says the read set
and the write set cannot be disjoint. Everything else — version numbers,
last-write-wins, read repair — is machinery for deciding *which* of the values
the read saw is the answer. The inequality is what guarantees the right one is
among them at all.

**Tunable consistency is a per-operation choice, not a cluster setting.** The
same store can serve a profile edit at W=2, R=2 and a view counter at W=1, R=1,
and both are correct for what they are. Cassandra and Riak expose it as a
per-request consistency level, and DynamoDB and MongoDB offer coarser versions
of the same choice; the mistake is not picking a weak level, it is picking one without
knowing which reads depend on which writes.

**W=N looks like the safe choice and is the one that breaks first.** It is the
strongest durability and the worst availability: with N=3 it gives you a store
that stops accepting writes the first time any single node reboots. R=N is the
same trade on the read side. A quorum's point is that it is a majority, not
everybody.

**Sending everything to one node is not a fix even when the tests pass.** It
makes read-your-write trivially true and leaves one copy of the data. Failures
do not arrive during the test; they arrive later, on the node everything was
pinned to.

**"Eventually consistent" describes a store that is converging.** This one was
not — no process was propagating anything, so a value written to one node stayed
on one node forever. Before reaching for the phrase, check that something is
actually doing the catching up: hinted handoff, read repair, anti-entropy, a
replication stream. If nothing is, the word for it is lost data.

</details>
