---
title: "3-2-1, and a copy the attacker cannot delete"
---

## The situation

`/ha/backups/backup.sh` dumps the shop every night into `/ha/backups/`, on
ops — the same machine, reachable with the same credentials, as the system
it protects.

The classic rule for backups is **3-2-1**: three copies of the data, on two
different kinds of storage, one of them off-site. Its modern addition is the
reason for this lesson: at least one copy **immutable** — one that nobody
holding production credentials can delete or change. Ransomware crews spend
days inside a network before they encrypt it, and one of the things they do
with that time is delete the backups.

There is an off-site server, `backupd`, running a
[restic REST server](https://github.com/restic/rest-server) with no options.
Its flags are in `/ha/backupd/options`, which it reads when it starts; in
production that file would be on a machine the shop's credentials cannot
reach. The job's credentials for it are already in `/ha/backups/backup.env`.

## Your objectives

1. `backup.sh` still keeps its local copy, and also sends each night's dump
   to a restic repository on `backupd`, using the credentials in
   `backup.env`.
2. An attacker holding everything on ops — `backup.env` included — cannot
   destroy that copy.

## What you're being graded on

The grader places an order, runs your `backup.sh`, and then becomes the
attacker. With only what is in `backup.env` it deletes every local backup,
runs `restic forget --prune` on every snapshot, and sends a `DELETE` for
every file in the repository.

Then it restores the latest snapshot from `backupd` into an empty Postgres,
and the order it placed must be there. Afterwards it puts your backups back
the way they were.

## Try it yourself

```
set -a; . /ha/backups/backup.env; set +a
restic init
restic backup /ha/backups/shop-*.dump
restic snapshots
docker exec devopslings-ha-backupd rest-server --help
```

<details>
<summary>Hint 1 — why another copy is not enough</summary>

Sending the dump to `backupd` gives you a second copy on a second machine.
It does not survive the attacker: the job needs credentials that can write
to the repository, the attacker has the job's credentials, and on a plain
server writing includes deleting. Try it — `restic forget` and `prune` work
as well for them as for you.

</details>

<details>
<summary>Hint 2 — what the server can refuse</summary>

Immutability has to be enforced by the *server*, against every client,
because the client is what gets compromised. `rest-server --append-only`
accepts new files and refuses to delete or overwrite existing ones. restic
needs nothing else to take a backup: it only ever adds.

</details>

<details>
<summary>Solution</summary>

```
echo "--append-only" > /ha/backupd/options
docker restart devopslings-ha-backupd

set -a; . /ha/backups/backup.env; set +a
restic init
```

and in `backup.sh`, after the `pg_dump`:

```
restic backup --quiet "$f"
```

With the server append-only, the attacker's `forget --prune` fails with `403
Forbidden`, and so does every `DELETE`.

### What append-only costs

Nothing can be deleted through the server, including by you: old snapshots
pile up. Retention becomes a job that runs *on the backup server*, as a
different identity, with its own credentials — `restic forget --prune`
pointed at the repository's directory directly, not at the REST endpoint.
That separation is the point: the identity that can delete backups must
not be one that production holds.

Object stores give the same guarantee as *object lock* (S3, MinIO, Ceph):
each object is written with a retention date, and in compliance mode not
even the account root can delete it before then. Tape in a vault and a disk
that is unplugged are the same idea, enforced by physics.

### The rest of 3-2-1

The grader checks the immutable copy, because that is the one that is easy
to get wrong. The other numbers matter too: the local copy is your fast
restore for the ordinary days, and the off-site copy only counts as off-site
if a fire, a flood or a cloud region outage cannot take it out together with
production. Lesson 9 is that outage.

</details>
