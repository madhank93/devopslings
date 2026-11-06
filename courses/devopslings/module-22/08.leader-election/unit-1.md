---
title: "Leader election: two schedulers, one job"
---

## The situation

The invoicing job must run once a second, on one node. Running it on web1
and web2 at the same time charges a customer twice. Both nodes run
`/ha/app/scheduler.sh`, and the script decides which of them is the leader.
Every run of the job is logged to `/ha/scheduler/runs` with its time and the
node that ran it.

The script looks reasonable. A node reads `scheduler/leader`. If the key is
empty or names the node itself, the node claims it under a five-second lease
and runs the job. With both nodes healthy, only one of them runs the job.

Cut the leader off from etcd and watch the log. The other node takes over
once the lease expires, and the old leader keeps running the job anyway.
For as long as the partition lasts, two nodes run the job.

## Your objectives

1. With both nodes healthy, exactly one node runs the job.
2. A leader cut off from etcd stops running the job, and the other node
   takes over on its own.
3. After the partition heals, one node runs the job again, not two.
4. When the leader crashes, the other node takes over, and the crashed
   node comes back as a follower.

Saving `/ha/app/scheduler.sh` restarts it on both nodes within a second.
Its output is in `/ha/web1/scheduler.log` and `/ha/web2/scheduler.log`.

## What you're being graded on

The grader replaces `/ha/scheduler/job` with its own copy and only reads the
run log. It takes any 5-second window and requires exactly one node in it.
It cuts the leader off from the back network for 20 seconds. In that time
the old leader must not run the job, starting 1.5 seconds after the cut, and
the other node must start running it. Then it heals the partition, kills
the leader's container for 12 seconds, and expects the other node to take
over and to keep the job once the crashed node is back.

## Try it yourself

```
tail -f /ha/scheduler/runs
etcdctl --endpoints=http://etcd1:2379 get scheduler/leader -w json
node cut web1 back; sleep 15; tail -n 20 /ha/scheduler/runs; node heal web1 back
tail /ha/web1/scheduler.log
```

<details>
<summary>Hint 1 — why the cut-off leader keeps going</summary>

Look at what the script does when an etcd command fails. The `get` returns
nothing, and an empty key looks like "nobody leads". The script then tries
to claim the key, fails at that too, and runs the job anyway. It treats
every error as permission.

A node cut off from etcd cannot tell whether it is still the leader. The
only safe reading of that uncertainty is that it is not.

</details>

<details>
<summary>Hint 2 — claiming has to be atomic</summary>

"Read the key, see it empty, write it" is two steps. Two nodes can both see
it empty and both write it. An etcd transaction makes the check and the
write one step: put the key only if it has never been created
(`create("scheduler/leader") = "0"`).

```
printf 'create("scheduler/leader") = "0"\n\nput scheduler/leader web1 --lease=<id>\n\n\n' \
  | etcdctl --endpoints=http://etcd1:2379 txn
```

</details>

<details>
<summary>Hint 3 — renew, then check, then act</summary>

Before each run, the node has to show that it still leads. First, renew its
lease with `lease keep-alive --once`. Second, read the key back and confirm
it names this node. If either step fails, the node does not run the job,
and it starts again with a new lease. Keep the timeouts the script already
sets. `lease keep-alive --once` ignores `--command-timeout` and waits for
etcd indefinitely, which is why every call is also wrapped in `timeout 2`.

</details>

<details>
<summary>Solution</summary>

```
#!/bin/bash
E="timeout 2 etcdctl --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 --dial-timeout=1s --command-timeout=1s"
me=$(hostname)
lease=""
while :; do
  [ -z "$lease" ] && lease=$($E lease grant 5 2>/dev/null | awk '{ print $2 }')
  if [ -n "$lease" ] && $E lease keep-alive --once "$lease" >/dev/null 2>&1; then
    printf 'create("scheduler/leader") = "0"\n\nput scheduler/leader %s --lease=%s\n\n\n' "$me" "$lease" \
      | $E txn >/dev/null 2>&1 || true
    [ "$($E get scheduler/leader --print-value-only 2>/dev/null)" = "$me" ] && /ha/scheduler/job
  else
    lease=""
  fi
  sleep 1
done
```

### The lease is the leadership

The leader key exists only as long as its lease is renewed. A leader that
crashes or loses its network stops renewing, the lease expires after five
seconds, and etcd deletes the key. Nobody has to notice that the leader is
gone. The other node simply finds the key free and claims it.

Expiry protects the cluster. It does not stop the old leader from running
the job, because the old leader may never learn that its lease has expired.
So the rule has to be enforced from the leader's side. A node acts only
right after it has proven, through a quorum, that it still holds the lease.
Each such proof is good for less than one lease period. A cut-off node
fails the proof on the next tick and stops, about four seconds before etcd
could give the key to anyone else.

This keeps the overlap small. It does not make it zero. A node that was
paused between its check and its run can still act on a lease that has
already expired. Systems that cannot tolerate even that pass a fencing
token, such as the leader key's create revision, to the resource the job writes to. The
resource then rejects any token older than the newest one it has seen.

</details>
