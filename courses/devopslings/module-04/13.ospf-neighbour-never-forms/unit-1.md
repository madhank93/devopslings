---
title: "one branch is in the routing table and the other never arrives"
---

## The situation

This box is the core router. It runs OSPF, using FRR, to two branch routers
over two identical circuits:

```
to-edge1 10.80.1.1/30  ->  edge1  ->  branch 1, 10.81.1.0/24
to-edge2 10.80.2.1/30  ->  edge2  ->  branch 2, 10.81.2.0/24
```

Nobody typed a route to either branch. The point of a routing protocol is that
routers tell each other what they can reach. Branch 2 arrived that way:

```
$ ip route show proto ospf
10.81.2.0/24 nhid 34 via 10.80.2.2 dev to-edge2 metric 20
```

Branch 1 never did. Both circuits are up, and both branch routers run OSPF on
their side of the link. Neither of them shows up on the other's list:

```
$ vtysh -c 'show ip ospf neighbor'
Neighbor ID     Pri State     ...  Address       Interface
10.80.255.3       1 Full/-    ...  10.80.2.2     to-edge2:10.80.2.1
```

## Your objective

Make branch 1's subnet reachable from this box, learned through OSPF the way
branch 2's is, and make the fix survive a restart of `frr.service`. The branch
routers belong to the branch team. You can read them with `vtysh -N edge1`, but
change only this box, and keep branch 2 working.

## What you're being graded on

`edge1` is a `Full` OSPF neighbour and `10.81.1.0/24` is in the kernel table
`proto ospf`. `10.81.1.1:8080` answers. `edge1`'s config is untouched, `edge2`
is still `Full`, and `/etc/frr/frr.conf` agrees with what's running.

<details>
<summary>Hint 1: is anything crossing the link?</summary>

OSPF routers find each other by multicasting a **hello** to `224.0.0.5` on every
interface OSPF runs on. Two routers that hear each other's hellos, and agree
with them, become neighbours, exchange their link-state databases, and reach
`Full`. Only then do routes appear.

```
$ tcpdump -ni to-edge1 proto ospf
IP 10.80.1.1 > 224.0.0.5: OSPFv2, Hello, length 44
IP 10.80.1.1 > 224.0.0.5: OSPFv2, Hello, length 44
IP 10.80.1.2 > 224.0.0.5: OSPFv2, Hello, length 44
```

Hellos are going both ways. Look at how often each side sends one.

</details>

<details>
<summary>Hint 2: a hello is also a contract</summary>

A hello says "I'm here", and it also carries settings both ends must agree on.
A router that receives a hello with a different value **discards it**, as if it
had never arrived. Compare the two ends:

```
$ vtysh -c 'show ip ospf interface to-edge1' | grep Timer
  Timer intervals configured, Hello 1s, Dead 4s, Wait 4s, Retransmit 5
$ vtysh -N edge1 -c 'show ip ospf interface core0' | grep Timer
  Timer intervals configured, Hello 10s, Dead 40s, Wait 40s, Retransmit 5
```

FRR also says so, if you ask the journal:

```
$ journalctl -n 50 | grep -i mismatch
... RouterDeadInterval mismatch on to-edge1:10.80.1.1 (expected 4, but received 40).
```

</details>

<details>
<summary>Hint 3: the running config and the saved one</summary>

`vtysh` changes the daemon that's running. `/etc/frr/frr.conf` is what
`frr.service` loads when it starts. They're separate until you run
`write memory`.

</details>

## Why it never forms

The fields both ends of an OSPF link must agree on are the area, the network
mask (on broadcast links), the authentication, the stub flags, and the **hello and dead intervals**.
The last two catch people out. A short hello is a legitimate tuning knob: it
detects a dead neighbour in 4 seconds instead of 40. But it's a setting on the
*link*, not on one end of it.

Someone set it on the core's end of the branch-1 circuit for a change ticket
and never got it onto the CPE. Since then, every hello `edge1` sends arrives
saying "dead interval 40" at a router that expects 4, and gets thrown away.
Every hello the core sends gets the same treatment in the other direction.
Nobody ever becomes a neighbour, so no database is exchanged and no route is
learned.

Nothing is down. The interfaces are up, the daemons are running, and packets
cross the link once a second. The failure is two routers politely declining to
talk to each other.

## The fix

<details>
<summary>Solution</summary>

Put the core's end back to the timers `edge1` uses, and save it:

```
$ vtysh
core# configure terminal
core(config)# interface to-edge1
core(config-if)# no ip ospf hello-interval
core(config-if)# no ip ospf dead-interval
core(config-if)# end
core# write memory
core# show ip ospf neighbor
10.80.255.2       1 Full/-    ...  10.80.1.2     to-edge1:10.80.1.1
10.80.255.3       1 Full/-    ...  10.80.2.2     to-edge2:10.80.2.1
```

Give it a few seconds after `Full` for the databases to sync and SPF to run,
then:

```
$ ip route show proto ospf
10.81.1.0/24 nhid 41 via 10.80.1.2 dev to-edge1 metric 20
10.81.2.0/24 nhid 34 via 10.80.2.2 dev to-edge2 metric 20
```

If the fast failover is still wanted, it's a change for *both* ends, made with
the branch team.

</details>

## What not to do

**Add a static route to `10.81.1.0/24`.** Branch 1 answers again, and the core
no longer learns anything about it. On the day that circuit fails, the static
route stays in the table and keeps sending traffic into a dead link. That day
was the reason for running a routing protocol.

**Change `edge1` to match.** The adjacency forms, and you've reconfigured
another team's router to a one-second hello on hardware nobody checked could
take it.

**Fix it in `vtysh` and stop.** It works until the next `systemctl restart frr`,
which loads the old file, and branch 1 vanishes again after a reboot nobody
links to this.

**Remove only the hello interval.** FRR doesn't derive the dead interval from
the hello, so a leftover `dead-interval 4` still mismatches.

## Carrying this forward

When a dynamic route is missing, ask the questions in the protocol's order. Is
there a neighbour, is it `Full`, and is the prefix in the database? Only then
ask whether it's in the kernel's table. A missing neighbour with hellos visible
on the wire almost always means a parameter mismatch, and both ends' `show ...
interface` output side by side shows which.

The next lesson moves from the protocol inside one network to the one between
networks. A BGP session can be up and healthy and still not carry the one route
it exists for.
