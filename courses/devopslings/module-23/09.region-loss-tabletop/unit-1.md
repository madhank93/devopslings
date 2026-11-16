---
title: "Tabletop: the region is gone"
---

## The situation

This one is a tabletop exercise: nothing is broken in the sandbox, and the
plan is the deliverable.

At 09:12 the shop's cloud region, **eu-1**, stops answering. Not one server
— the region: its compute, its storage, its network. The provider's status
page says six hours. The shop cannot be closed for six hours.

`/ha/dr/inventory.txt` lists everything the shop runs on, which region it
is in, and how long a recovery step that uses it takes at least.
`/ha/dr/roster.txt` says who is who today.

## Your objectives

Write the plan in `/ha/answers/region-loss.txt`:

1. The RPO and RTO it meets — within the shop's 15 and 60 minutes.
2. Who makes the failover decision.
3. The steps after that decision, in order: how many minutes each takes,
   which inventory items it uses, and what it does.

## What you're being graded on

- the decision owner is someone the roster allows to make that call;
- no step uses anything in eu-1;
- each step allows at least the minutes its inventory items take, and the
  steps add up to no more than your RTO;
- the database comes back from data recent enough for your RPO;
- the plan gives the shop everything it needs to take an order: somewhere to
  run, the images to run, the secrets they start with, the data, and a way
  for customers to reach it.

<details>
<summary>Hint 1 — read the inventory twice</summary>

First pass: cross out every line in eu-1. Second pass: for each thing the
shop needs to serve an order, find what is left. Some of the crossings-out
are not obvious on the day — the replica, the DNS, the wiki with the
runbook in it.

</details>

<details>
<summary>Hint 2 — the data</summary>

Three things in us-2 hold the database: a nightly dump, a base backup synced
every four hours, and a WAL archive a couple of minutes behind. How old can
each be when the region dies? The WAL archive on its own restores nothing:
it is replayed onto a base backup.

</details>

<details>
<summary>Hint 3 — the clock</summary>

The RTO clock starts at the decision. Compute, data, secrets, images and DNS
each take a fixed minimum here, and they are done one after another. Add
them up before you add anything else.

</details>

<details>
<summary>Solution</summary>

```
rpo_minutes: 15
rto_minutes: 60
decision_owner: priya

step: 5  | vm-pool-us2, runbooks-git | boot the spare app servers in us-2, following the git copy of the runbook
step: 20 | basebackup-us2            | restore the newest base backup onto a us-2 database server
step: 15 | wal-archive-us2           | replay the cross-region WAL archive to its end, then promote
step: 10 | bao-escrow-us2            | two officers open the escrow; import the secrets into a new OpenBao
step: 5  | registry-mirror-us2       | deploy the app from the us-2 mirror, pointed at the restored database
step: 5  | dns-provider, pager       | promote the managed DNS to primary, point www at us-2, tell support
```

60 minutes. Data at most 7 minutes old: eu-1 archived WAL every 300 seconds
and the copy is under two minutes behind.

### The traps

- **The replica.** A replica in the same region is high availability, not
  disaster recovery. It goes down with the region.
- **The runbook.** The wiki is in eu-1. A plan that starts "open the runbook"
  fails at step one unless the runbook is somewhere else too.
- **The secrets.** OpenBao is in eu-1. Without the escrowed copy in us-2,
  the restored database has no credentials for the app to log in with.
- **The DNS.** Self-hosted DNS in eu-1 means customers cannot be told where
  the shop moved. The managed secondary is what makes the move visible.
- **The decision.** The on-call engineer is the first person awake, and the
  wrong person to decide alone: failing over a region is expensive, hard to
  undo, and may race the provider's own recovery. Name who decides, and make
  sure they can be reached without anything in eu-1.

### What a tabletop is for

You will not get to rehearse losing a real region very often. A tabletop is
the cheap version: walk the plan line by line against the inventory and ask,
for every step, "where does that live?". The answer is often the region that
just died. Then fix the inventory, not the plan — the escrowed secrets, the
mirrored registry, the runbooks in git — so the plan has something to stand
on.

</details>
