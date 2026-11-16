---
title: "Split brain: three members, two gone"
---

## The situation

etcd stores the shop's coordination state: which version is deployed, which
features are switched off. Three members, etcd1 to etcd3, agree on every
write by majority. Two of three is a majority. One of three is not.

`/ha/etcd/INCIDENT.txt` has the timeline. In short: a partition cut etcd1
off, and etcd2 and etcd3 carried on as a majority of two. Services kept
reading and writing their config through them, and the deploy pipeline
wrote `deploy/version=42`. Then both went down. etcd1, alone,
refused every write, which is the behaviour it is supposed to have. The
on-call did not want that, so they restarted etcd1 with
`ETCD_FORCE_NEW_CLUSTER=true` and it started taking writes. They used that to
disable payments.

Twelve minutes later someone started etcd2 and etcd3 again. Both exited
within seconds.

## Your objectives

1. etcd1, etcd2 and etcd3 are running, healthy, and each one lists the same
   three started members under one cluster id.
2. Everything the majority stored is kept on every member: `deploy/version`
   is `42`, along with the config writes nobody wrote down.
3. `flags/payments` is `disabled` on every member: the on-call's decision
   stands, even though the write that recorded it is lost.
4. No member is left configured to force a new cluster the next time it
   restarts.
5. With two members killed, the third refuses writes. With them back, the
   cluster takes writes again.

Each member reads `/ha/etcd/<member>.env` when it starts. Any `ETCD_*`
variable there overrides the default, and `docker restart` or `node start`
applies it.

## What you're being graded on

The grader checks every member's own view — its health, its member list, its
cluster id and its copy of the keys — rather than asking one member and
trusting the answer. Then it kills etcd2 and etcd3, tries a write on etcd1,
which must fail, starts them again, and expects a write to succeed within 30
seconds.

## Try it yourself

```
cat /ha/etcd/INCIDENT.txt
etcdctl --endpoints=http://etcd1:2379 member list
etcdctl --endpoints=http://etcd1:2379 get --prefix ''
node start etcd2; sleep 5; docker logs --tail 20 devopslings-ha-etcd2
```

<details>
<summary>Hint 1 — why etcd2 and etcd3 will not stay up</summary>

`ETCD_FORCE_NEW_CLUSTER` rewrote etcd1's membership to a list of one. When
etcd2 starts it contacts its peers, and etcd1 answers that etcd2 is not a
member of its cluster. etcd2 takes that at face value and shuts down for
good: "the member has been permanently removed from the cluster".

As long as etcd1 runs with that history, it ejects anyone who tries to
rejoin.

</details>

<details>
<summary>Hint 2 — two histories, and which one is real</summary>

There are now two copies of the data. etcd1's has `deploy/version=41` and
`flags/payments=disabled`. etcd2's and etcd3's have `deploy/version=42`
and every config write services made during the partition. Neither copy
contains everything, and only one of them can be completed by hand: the
on-call's write is one line in the timeline, while the majority's writes
are recorded nowhere but in its own data.

One of them came from a quorum and the other did not. The pipeline was told
its write succeeded because two of three members agreed to it. The on-call's
write was agreed to by a cluster that one person had declared into
existence. Keep the history that had a quorum, and redo the other write
yourself.

</details>

<details>
<summary>Hint 3 — rejoining a member</summary>

A member with the wrong history cannot be merged back in. It is removed and
added again empty, and it then copies everything from the leader:

```
etcdctl --endpoints=http://etcd2:2379 member remove <id>
etcdctl --endpoints=http://etcd2:2379 member add etcd1 --peer-urls=http://etcd1:2380
```

The re-added member has to start with an empty data directory and
`ETCD_INITIAL_CLUSTER_STATE=existing`. Pointing `ETCD_DATA_DIR` somewhere
new gives it an empty directory without deleting the old one.

</details>

<details>
<summary>Solution</summary>

```
payments=$(etcdctl --endpoints=http://etcd1:2379 get flags/payments --print-value-only)
node kill etcd1
node start etcd2; node start etcd3
# wait until a write through etcd2 succeeds: etcd2 and etcd3 are a quorum again
id=$(etcdctl --endpoints=http://etcd2:2379 member list | awk -F', ' '$3 == "etcd1" {print $1}')
etcdctl --endpoints=http://etcd2:2379 member remove "$id"
etcdctl --endpoints=http://etcd2:2379 member add etcd1 --peer-urls=http://etcd1:2380
cat > /ha/etcd/etcd1.env <<'ENV'
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_DATA_DIR=/var/lib/etcd/rejoined
ENV
node start etcd1
etcdctl --endpoints=http://etcd2:2379 put flags/payments "$payments"
```

Stop etcd1 first. While it runs it keeps telling the other two they have
been removed. `member add` can be refused for a few seconds after the
cluster comes back, until every remaining member has been connected long
enough to be counted.

### What forcing the survivor actually did

Quorum is how a cluster stays one cluster. A partition creates two groups,
and each can see only itself. The rule that only a majority may write
ensures that at most one group writes. A forced single-member cluster
throws that rule away. Afterwards there are two histories that both claim to
be authoritative, and no automatic way to merge them. A system that has
lost its quorum is unavailable on purpose. Forcing it to accept writes makes
it inconsistent, and the inconsistency stays until someone sorts it out by
hand.

`--force-new-cluster` has a legitimate use: disaster recovery when the other
members are gone for good and the survivor's data is the best there is. It
was the wrong tool here because the other members were only down. The
survivor was the minority, and its history was the one to throw away.

</details>
