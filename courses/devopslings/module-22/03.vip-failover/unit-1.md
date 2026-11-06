---
title: "VIP failover, and the four seconds nobody measured"
---

## The situation

`www` is 172.29.22.100. It belongs to no container: keepalived adds it to the
interface of whichever load balancer is the VRRP *master*, and announces it
with a gratuitous ARP. Today only lb1 runs keepalived, so when lb1 dies the
address dies with it.

The fix everyone knows is to run keepalived on lb2 as a backup. The master
sends an advertisement every `advert_int` seconds; the backup, hearing none
for long enough, takes the address. The design doc says failover is
"instant". Nobody has timed it.

## Your objectives

1. Give lb2 a keepalived config so it takes `www` when lb1 stops.
2. With both nodes on `advert_int 1`, measure the failover: freeze the
   holder and see how long `www` is unreachable. Write that number as
   `measured_before` in `/ha/answers/failover.txt`.
3. Get the gap to **2 seconds or less**.
4. Never let both nodes hold the address at once.

Each node reads `/ha/<node>/keepalived.conf` and restarts keepalived within
a second of a change. A config keepalived rejects is reported in
`/ha/<node>/log`.

## What you're being graded on

- **A measurement.** `measured_before` is a number of seconds in the range an
  untuned pair actually produces.
- **One holder.** With both nodes healthy, exactly one of them has the
  address.
- **Inside the budget.** The grader freezes whichever node holds `www`
  (`docker pause`: the process is stuck, the address is still configured)
  and requests `www` every 50ms. The longest run of failures must be at most
  2 seconds, and the other node must hold the address.
- **No split VIP.** After the frozen node wakes up, exactly one node holds
  the address, and keeps holding it.

## Try it yourself

```
(sleep 2; node pause lb1) & gapwatch 10; node resume lb1
docker exec devopslings-ha-lb2 ip -br addr show eth0
```

<details>
<summary>Hint 1 — the second config</summary>

Start from a copy of lb1's file. The backup needs `state BACKUP` and a lower
`priority`. Everything that identifies the group — `virtual_router_id`, the
address, and the protocol settings — has to be the same on both, or they are
two separate routers that each elect themselves.

</details>

<details>
<summary>Hint 2 — where the seconds go</summary>

A backup treats the master as dead after the *master down interval*:
three advert intervals plus a skew of `(256 - priority) / 256` of one. At
`advert_int 1` that is about 3.6 seconds before the backup even starts, and
then ARP caches have to follow. That is the number you measured.

</details>

<details>
<summary>Hint 3 — smaller than a second</summary>

VRRP version 2 counts advert intervals in whole seconds. Version 3 allows
fractions. Set `vrrp_version 3` in a `global_defs` block — on both nodes, since
a v2 router and a v3 router do not understand each other's adverts.

</details>

<details>
<summary>Solution</summary>

`/ha/lb1/keepalived.conf` (lb2's is the same with `state BACKUP` and
`priority 100`):

```
global_defs {
    vrrp_version 3
}
vrrp_instance www {
    state MASTER
    interface eth0
    virtual_router_id 22
    priority 150
    advert_int 0.2
    virtual_ipaddress {
        172.29.22.100/24
    }
}
```

and `measured_before: 3.6`, or whatever your machine showed.

### Why the default was four seconds

Nobody chose four seconds. `advert_int 1` is the default, the master down
interval is three of them plus skew, and gratuitous ARP and the clients' retry
timing add the rest. "Failover is instant" was a statement about the
mechanism, not a measurement of it. Every HA claim has a number like this
inside it, and it is only known once someone has frozen the primary and
watched.

### What the shorter interval costs

At 0.2 seconds, a master that stalls for 0.7 seconds — a long GC pause, a
saturated CPU, a slow hypervisor — is replaced while it is still alive. When
it comes back, it preempts and the address moves again: two failovers for no
failure. The interval is a trade between how long users wait during a real
failure and how often you fail over without one. Pick it from the budget, and
measure both.

### Why the split VIP matters

Two masters both answer ARP for the address. Clients and switches pick
whichever reply they saw last, so traffic lands on both, and anything that
assumed one active node — a cache, a lock, a counter — is now wrong in two
places. It happens whenever the two routers stop agreeing they are in the
same group: a mismatched `virtual_router_id`, a different VRRP version, or a
network where the adverts do not arrive.

</details>
