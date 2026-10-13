---
title: "the firewall rule is there, and its counter has never moved"
---

## The situation

`fw1` is the router and firewall between the office LAN (`10.88.0.0/24`) and
the server network (`10.88.1.0/24`). Security ticket SEC-311 asked for the
admin console on `srv` (`10.88.1.10:9000`) to be unreachable from the office.
A rule went in the same afternoon. From the office:

```
$ ip netns exec office curl -s -m 3 http://10.88.1.10:9000/
admin-console-2026
```

The rule is there, and it matches this traffic exactly: source office, TCP,
port 9000. Its counter says it has never seen a packet:

```
$ ip netns exec fw1 iptables -L -v -n
Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target  prot opt in  out  source         destination
    0     0 DROP    tcp  --  *   *    10.88.0.0/24   0.0.0.0/0    tcp dpt:9000

Chain FORWARD (policy ACCEPT 26 packets, 1946 bytes)
 pkts bytes target  prot opt in  out  source         destination

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
```

## Your objective

Make the admin console unreachable from the office, keep the app on `:8080`
reachable, and make it survive a reboot of `fw1`. The fix goes on `fw1`, not on
`srv`, and the console keeps running.

## What you're being graded on

The office can't reach `:9000` and can still reach `:8080`. A `FORWARD` rule on
`fw1` does the blocking, it's in `/etc/fw1/rules.v4`, and `srv` has no rules
of its own.

<details>
<summary>Hint 1: read the counters, not just the rules</summary>

Every rule and every chain policy keeps a packet counter. A rule that should be
matching and reads `0` isn't wrong. Packets aren't being checked against it.
Look at which counter in that output is moving.

</details>

<details>
<summary>Hint 2: three doors</summary>

Every packet that reaches a Linux box after routing goes through exactly one of
three filter chains:

- **INPUT** for packets addressed *to this box*
- **FORWARD** for packets *passing through* this box to somewhere else
- **OUTPUT** for packets this box *originates*

The office's packet is addressed to `10.88.1.10`. `fw1` isn't the destination,
it's a hop on the way.

</details>

## Why the rule never fires

The kernel decides INPUT or FORWARD by routing first. If the destination is one
of the box's own addresses, the packet goes up to INPUT and a local socket. If
not, it goes to FORWARD and back out another interface. The two paths never
cross, so a router's INPUT chain protects the router itself: its SSH, its own
services. Here it protects a port that `fw1` doesn't even have open.

That's why this mistake is so common. On a single host, "the firewall" is the
INPUT chain, and that habit carries over to routers, where the traffic that
matters never enters INPUT. The policy counter on FORWARD climbing with every
request is the giveaway.

## The fix

<details>
<summary>Solution</summary>

Move the rule to FORWARD in the boot file and reload it:

```
-A FORWARD -s 10.88.0.0/24 -d 10.88.1.10/32 -p tcp -m tcp --dport 9000 -j DROP
```

```
$ systemctl reload fw1-firewall.service
$ ip netns exec office curl -s -m 3 http://10.88.1.10:9000/ ; echo $?
28
$ ip netns exec fw1 iptables -L FORWARD -v -n
    3   180 DROP  tcp  --  *  *  10.88.0.0/24  10.88.1.10  tcp dpt:9000
```

The counter moves now. That's how you confirm a firewall rule works: watch it
match, rather than assuming it does from the fact that the symptom went away.

</details>

## What not to do

**Put the rule on `srv`.** It works, and it's in the wrong place. `fw1` is the
boundary. The next server on `10.88.1.0/24` gets no protection, and the app
team now owns a security control they didn't ask for.

**OUTPUT, or another INPUT variant.** Neither path carries this packet.

**Stop the console.** That isn't blocking it. Everyone who should reach it
loses it too.

**Add the rule live and stop.** `fw1-firewall.service` loads
`/etc/fw1/rules.v4` at boot, and the next reboot reopens the console.

## Carrying this forward

Before writing a filter rule, ask whose address is in the destination field.
If it's this box's, the rule goes in INPUT. If it's anyone else's, the rule
goes in FORWARD. After writing it, generate the traffic and watch the counter.
A rule whose counter never moves is probably in a chain that traffic doesn't
pass through.
