---
title: "the queue lost jobs overnight and nobody deleted anything"
---

## The situation

Redis holds two things. The page cache, written by the nightly warm, is a copy
of what Postgres can rebuild in a second. The job queue — `queue:jobs` and one
`job:<id>` hash per entry — is the only copy of work a customer has already
been told was accepted.

A month ago Redis was OOM-killed, so it was given a 32MB ceiling and the
eviction policy that made the errors stop. The errors stopped.

Last night 200 jobs were queued. Then the cache warm ran:

```
/work/app/enqueue.sh 200
/work/app/cache-warm.sh
redis-cli LLEN queue:jobs
```

This morning the queue is empty and no worker ever popped it. Nobody deleted
anything, nothing errored, and the cache is cold too — as it is every time the
box restarts.

## Your objectives

- Make the job queue survive both the cache warm and a restart of Redis
- Keep the page cache working under the same 32MB ceiling

## What you're being graded on

The grader queues 25 jobs, kills Redis the way the OOM killer did, starts it
again, and expects all 25 back. Then it
clears the cache, runs `/work/app/cache-warm.sh` against the ceiling, and
requires that Redis evicted keys, that none of them were the queue, that no
write was refused, and that a usable cache is left standing. You also fill in
`/work/answers/redis-eviction.md`.

<details>
<summary>Hint 1 — ask Redis what it threw away</summary>

Redis keeps the count:

```
redis-cli INFO stats  | grep -E 'evicted_keys|expired_keys'
redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human|maxmemory_policy'
```

`expired_keys` is a key reaching its TTL. `evicted_keys` is Redis reaching the
ceiling and choosing something to delete to make room. They are different
events and only one of them is a decision Redis made on your behalf.

Watch the counter move while the warm runs, and watch `LLEN queue:jobs` at the
same time.

</details>

<details>
<summary>Hint 2 — the policy name says which keys are in the draw</summary>

`maxmemory-policy` has two families. The `allkeys-*` policies choose a victim
from every key in the database. The `volatile-*` policies choose only from keys
that have an expiry set. `noeviction` chooses nothing and refuses the write
instead.

```
redis-cli CONFIG GET maxmemory-policy
redis-cli TTL queue:jobs
redis-cli TTL cache:page:1
```

A TTL is not housekeeping here. It is the only signal Redis has that a key is a
copy of something else, and under a `volatile-*` policy it is what makes a key
eligible at all. Which means switching the policy without going back to what
writes the cache leaves Redis at the ceiling with nothing it is allowed to take
— and a cache full of keys that never expire is exactly that situation. If the
warm starts failing with `OOM command not allowed`, that is what it is telling
you, and last night's un-expiring pages are still sitting there.

</details>

<details>
<summary>Hint 3 — a setting only lasts as long as the process it was set on</summary>

`CONFIG SET` changes the running server. It does not change the file the
server reads when it starts, so a restart quietly undoes it — which is the same
shape as the original bug: something that looked fixed because the symptom
stopped.

```
redis-cli CONFIG GET appendonly
redis-cli CONFIG GET save
redis-cli CONFIG REWRITE
```

This Redis was started from `/data/redis.conf` on its own volume, so
`CONFIG REWRITE` has somewhere to write. Look at the file before and after.

For durability there are two mechanisms. `appendonly yes` logs every write and
replays the log at startup, losing at most a second by default. Save points —
`save 60 1000` — snapshot the whole dataset periodically and on a clean
shutdown, and lose everything since the last snapshot on an unclean one. A
queue that has already told a customer "accepted" wants the first.

</details>

<details>
<summary>Solution</summary>

Three changes, and the third is the one people forget.

```bash
# Choose victims only from keys that say they are disposable.
redis-cli CONFIG SET maxmemory-policy volatile-lru

# The queue is the only copy of the work it holds.
redis-cli CONFIG SET appendonly yes

# Neither of those outlives the process until it is written back.
redis-cli CONFIG REWRITE
```

Then the writer, in `/work/app/cache-warm.sh`:

```bash
echo "SET cache:page:$i $body EX 3600"
```

and last night's pages, written without a TTL and therefore un-evictable under
the new policy, get dropped once so the next warm can write them properly:

```bash
redis-cli --scan --pattern 'cache:*' | xargs -r redis-cli UNLINK
```

The ceiling never moved. Redis still evicts thousands of keys during the warm.
It just no longer has the queue in its list of candidates.

### The part worth remembering

**`maxmemory-policy` is a data classification, not a tuning knob.** The choice
is not "which eviction algorithm is fastest" — LRU against LFU is a rounding
error next to it — but "which of my keys am I willing to lose". `allkeys-*`
says *all of them*, which is a true statement about a pure cache and a false
one about every Redis that has ever also held a queue, a session, a lock, or a
rate-limit counter.

**A TTL is how a key declares itself a copy.** Under `volatile-*` it is load
bearing: keys without one are not candidates, so a cache written with no expiry
turns the ceiling into `OOM command not allowed` instead of eviction. Setting
the policy and not the TTLs converts silent data loss into loud write failures
— an improvement, and not the fix.

**Two workloads in one Redis is a decision, not an accident.** One instance is
cheaper and it forces one eviction policy and one persistence setting onto
keyspaces that want opposite ones. The TTL trick makes a single instance work;
separate instances — or separate databases with separate limits, on a managed
Redis that supports it — make it work without relying on every future writer
remembering.

**`CONFIG SET` is not `CONFIG REWRITE`.** A fix that disappears on restart is
the same class of bug as the one it fixed: the symptom stops, nothing is
recorded, and it comes back on a night nobody is watching. Better still, the
config file belongs in the repository that deploys the box, and `CONFIG SET` is
what you do to avoid the restart until the deploy lands.

**Raising `maxmemory` is not wrong, it is just not an answer.** A cache grows
until something stops it. More headroom moves the date of the next incident and
changes nothing about which keys get chosen when it arrives.

</details>
