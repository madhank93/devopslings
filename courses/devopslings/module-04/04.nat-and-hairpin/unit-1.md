---
title: "everyone can reach the service except the network it lives on"
---

## The situation

A service runs at `10.88.0.5:8080` and is published at `203.0.113.10:80` by a
DNAT rule. From outside, it works:

```
$ ip netns exec outside curl http://203.0.113.10/
published-svc-2026
```

From `client` — a machine on the service's own subnet, `10.88.0.6` — it does
not:

```
$ ip netns exec client curl -v http://203.0.113.10/
*   Trying 203.0.113.10:80...
* Recv failure: Connection reset by peer
```

Reset, not timeout. Something answered and the answer was rejected.

The rule is firing. The counter proves it:

```
$ nft list table ip pubnat
    ip daddr 203.0.113.10 tcp dport 80 dnat to 10.88.0.5:8080
```

And the service receives the request — it logs a `GET /` from `10.88.0.6` and
returns 200. The request works. Only the reply does not.

## Your objective

Make the published address work from the internal network too, while keeping it
working from outside. The client must keep asking for `http://203.0.113.10/`,
the service stays where it is, and the DNAT rule stays.

## What you're being graded on

The DNAT rule still present, the service still in its own namespace with nothing
listening beside it, `br_netfilter` still off, and `203.0.113.10` serving both
from outside and from `10.88.0.6`.

<details>
<summary>Hint 1 — follow one packet all the way round</summary>

Write down the four addresses at each step for the client's request. Source and
destination, on the way out and on the way back.

The client sends to `203.0.113.10:80`. What does the service receive? What does
it send back, and — this is the one — *to whom*, and *from what address*?

</details>

<details>
<summary>Hint 2 — watch it from the service's side</summary>

```
$ ip netns exec svc tcpdump -i any -nn tcp port 8080
IP 10.88.0.6.43558 > 10.88.0.5.8080: Flags [S]
IP 10.88.0.5.8080 > 10.88.0.6.43558: Flags [S.]
```

The reply goes straight from `10.88.0.5` to `10.88.0.6`. Both are on the same
subnet, so it is one hop over the bridge.

Now ask what the client is waiting for.

</details>

<details>
<summary>Hint 3 — un-translation is not automatic</summary>

Conntrack reverses a translation when the reply passes back through the machine
that made it. That reply does not pass back through the box at all.

So the fix has to make the reply come back through the box. There is only one
field you can change that forces that.

</details>

## What is actually happening

The client sends a SYN to `203.0.113.10:80`. That address is not on its subnet,
so it goes to the default gateway — the box. The box's prerouting chain rewrites
the destination to `10.88.0.5:8080` and records the translation in conntrack.
It then routes the packet, which goes straight back out of the interface it
arrived on, to the service. This U-turn is the **hairpin**.

The service replies. Its peer is `10.88.0.6`, which is on its own subnet, so it
answers directly over the bridge. The box never sees that packet — and a
translation the box does not see is a translation the box cannot reverse.

So the client, which opened a connection to `203.0.113.10:80`, gets a SYN-ACK
from `10.88.0.5:8080`. Its kernel has no socket matching that, and does the only
correct thing: **RST**.

Every layer behaved properly. The rule fired, the routing was right, the service
answered. The reply simply took a shortcut past the machine holding the only
copy of what the addresses used to be.

## The fix

<details>
<summary>Solution</summary>

Make the hairpinned traffic appear to come from the box:

```
$ nft add rule ip pubnat post \
    ip saddr 10.88.0.0/24 ip daddr 10.88.0.5 tcp dport 8080 masquerade
```

Now the service sees the request coming from `10.88.0.1`, the bridge, rather
than from `10.88.0.6`. `10.88.0.1` is the box, so the reply is sent to the box,
where conntrack still holds both translations and unwinds them in order: source
back to `203.0.113.10:80`, destination back to `10.88.0.6`. The client gets a
reply from the address it asked, and the connection completes.

The condition is deliberately narrow — internal source, this service, this port.
A blanket `masquerade` on the postrouting chain would also work and would hide
every internal client's address from every internal service.

**The cost, stated out loud:** the service now logs `10.88.0.1` for all internal
traffic. Per-client rate limiting, IP allow-lists and access logs all stop
distinguishing internal callers. That is the standard trade for hairpin NAT, and
it is the reason the better answer at scale is usually split-horizon DNS —
resolve the name to `10.88.0.5` inside and `203.0.113.10` outside, so the
internal packet never needs translating at all.

</details>

## A note on `br_netfilter`

This lesson turns off `net.bridge.bridge-nf-call-iptables`, and that deserves an
explanation, because with it on the problem does not reproduce.

Normally a frame bridged between two ports on the same subnet is switched, not
routed, and never goes near netfilter. `br_netfilter` changes that: bridged
frames are dragged through the IP hooks as well, so conntrack sees the service's
direct reply and un-translates it in passing. The Docker daemon enables this
host-wide, which is why hairpin NAT sometimes appears to work by itself on a
Docker host and stops working the moment the same configuration is deployed to
a plain router.

Relying on it is relying on an accident. It is machine-wide, it applies to every
bridge on the box, it costs performance on all bridged traffic, and it has
produced its own long history of surprising bugs.

## Carrying this forward

**"Reachable from everywhere except nearby" is a NAT symptom.** The shorter the
path, the more likely it bypasses the thing doing the translating.

**RST means something answered.** A timeout means nothing came back at all.
A reset means a reply arrived at a machine that could not match it to a socket —
almost always a wrong address, not a missing one.

**Translation is a pair.** Anything that rewrites a packet must see the reply,
and a route that lets the reply skip that machine breaks the pair. That is the
same fault as the previous lesson's asymmetric return path, one layer up.
