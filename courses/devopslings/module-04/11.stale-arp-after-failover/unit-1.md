---
title: "the address moved an hour ago, and this box is still knocking on the old door"
---

## The situation

The floating IP `10.70.0.100` failed over from `app-a` to `app-b` an hour ago.
It was a planned failover, it went cleanly, and `app-b` holds the address and
serves on it:

```
$ ip netns exec app-b curl -s http://10.70.0.100:8080/
vip-answers-2026
```

This box is on the same segment, `lan1`, at `10.70.0.1`. It can reach `app-b`'s
own address and it cannot reach the VIP:

```
$ curl -s -m 5 http://10.70.0.12:8080/
vip-answers-2026
$ curl -s -m 5 http://10.70.0.100:8080/
$ echo $?
28
```

It's the same host, port and subnet, and there's no firewall. The route is as
plain as a route gets:

```
$ ip route get 10.70.0.100
10.70.0.100 dev lan1 src 10.70.0.1 uid 0
```

There's no gateway in that line: the destination is *on-link*, so this box
delivers the packet itself. Routing has nothing left to get wrong. What's
left is the step after routing.

## Your objective

Make this box reach the service on `10.70.0.100` again, in a way that survives
the next failover and the next boot. `app-a` has been drained and stays that
way, so the VIP doesn't go back to it.

## What you're being graded on

The VIP stays on `app-b` and off `app-a`. This box fetches the page from
`10.70.0.100`. The box's neighbour entry for the VIP is learned rather than
pinned, and nothing on the box will re-pin it at boot.

<details>
<summary>Hint 1: an IP address is not where a frame goes</summary>

On an Ethernet segment a packet travels inside a frame, and the frame is
addressed to a **MAC address**, not an IP. Before this box can send anything to
`10.70.0.100` it has to know which MAC that IP is at. It finds out with ARP
("who has 10.70.0.100?") and stores the answer in the **neighbour table**.

The bridge `lan1` is a switch. It forwards each frame by destination MAC alone,
to whichever port that MAC was last seen on. It never looks at the IP.

```
$ ip neigh show 10.70.0.100
```

</details>

<details>
<summary>Hint 2: watch the frames, not the packets</summary>

`tcpdump -e` prints the link-layer header, which is the part that matters here:

```
$ tcpdump -eni lan1 tcp port 8080
32:ba:0f:f8:6b:a6 > 02:00:00:70:00:0a, ethertype IPv4 ... 10.70.0.1.38328 > 10.70.0.100.8080: Flags [S] ...
```

The IP header says `10.70.0.100` and the frame says `02:00:00:70:00:0a`. Find
out whose MAC that is:

```
$ ip netns exec app-a ip -br link show eth0
$ ip netns exec app-b ip -br link show eth0
$ bridge fdb show br lan1 | grep 02:00
```

</details>

<details>
<summary>Hint 3: why ARP did not correct it</summary>

A normal neighbour entry is a cache. It goes `STALE` after a while and gets
re-confirmed or re-learned, which is how a failover is supposed to propagate.
The new holder usually helps by sending a *gratuitous ARP* that says "this IP
is at my MAC now".

This entry is `PERMANENT`. The kernel never re-ARPs for a permanent entry and
ignores any ARP reply that contradicts it. Then ask where it came from, because
it didn't get there by itself:

```
$ grep -rl 10.70.0.100 /etc
$ systemctl cat pin-neighbours.service
```

</details>

## Why the frames vanish

`app-a` still exists. It's up and on the switch, and the bridge delivers every
frame addressed to its MAC faithfully. `app-a`'s kernel unwraps the frame and
finds an IP packet for `10.70.0.100`, an address it no longer holds. A host
that isn't a router discards a packet like that. It doesn't send a reset or an
ICMP error, and it writes no log line.

So every layer this box can see says yes. The route is on-link and the
interface is up. The bridge is forwarding and the service is listening on the
right host. The one wrong fact is in a table most people never print, and it's
wrong *on purpose*: someone pinned it, months ago, to stop a different outage.

`app-b`'s own address works because the box learned that entry the normal way,
through ARP, at `02:00:00:70:00:0b`.

## The fix

<details>
<summary>Solution</summary>

Take the pin out of the file that re-applies it at boot, then out of the live
table:

```
$ sed -i '/^10\.70\.0\.100[[:space:]]/d' /etc/neighbours.conf
$ ip neigh del 10.70.0.100 dev lan1
$ curl -s http://10.70.0.100:8080/
vip-answers-2026
$ ip neigh show 10.70.0.100
10.70.0.100 dev lan1 lladdr 02:00:00:70:00:0b REACHABLE
```

The next packet for the VIP finds no entry, so the kernel broadcasts an ARP
request. `app-b` answers, and the entry is now a cache like any other, free to
follow the VIP on the next failover.

Disabling `pin-neighbours.service` outright works too, as long as nothing else
on the box needs a pin.

</details>

## What not to do

**Pin it to `app-b` instead.** It works today. A floating IP exists to move, so
the next failover breaks this box again in the other direction, and nobody will
think to look here because "we fixed the ARP thing last time".

**Delete the entry and stop.** The live table is clean, and
`/etc/neighbours.conf` puts the stale pin back at the next boot. The outage
would come back on the box's next restart, months later, when nobody connects
it to this.

**Add a host route via `10.70.0.12`.** It sends the VIP's traffic to `app-b`'s
real address as a gateway, which works because `app-b` holds both. The wrong
entry is still in the table, and every other path to the VIP still hits it.

**Turn on forwarding on `app-a`** so it relays what it gets. You'd be making a
drained server into a router to cover for one stale table entry.

## Carrying this forward

When a host on the same subnet is unreachable and routing is on-link, the
question is no longer "which way?" but "which MAC?". `ip neigh show <ip>` answers
it in one line, and `tcpdump -e` shows what's actually on the wire.

A `PERMANENT` neighbour entry for an address that's meant to move is a fault
waiting for its failover. Static ARP does have legitimate uses, such as a
gateway that must never be spoofed. A floating IP isn't one of them.
