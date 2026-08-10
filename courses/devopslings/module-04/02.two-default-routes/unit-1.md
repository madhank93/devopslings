---
title: "the box answers on one uplink and ignores the other"
---

## The situation

This box has two uplinks to two different transit networks. Both are up. Both
have an address. The service is bound to `0.0.0.0`, so it is listening on both.

Network A's client is served. Network B's client times out.

```
$ ip netns exec netA curl --interface 10.10.0.10 http://192.168.10.2:8080/
box-answers-2026

$ ip netns exec netB curl --interface 10.20.0.20 http://192.168.20.2:8080/
curl: (28) Connection timed out after 5001 milliseconds
```

The usual conclusions are all available and all wrong. The interface is not
down:

```
$ ip -br addr show up-b
up-b   UP   192.168.20.2/24
```

The service is not bound to the wrong address — it is on `0.0.0.0`, and A works
through the same process. And the request is genuinely arriving:

```
$ tcpdump -i up-b -nn tcp port 8080
IP 10.20.0.20.51234 > 192.168.20.2.8080: Flags [S], seq 2891...
IP 10.20.0.20.51234 > 192.168.20.2.8080: Flags [S], seq 2891...
IP 10.20.0.20.51234 > 192.168.20.2.8080: Flags [S], seq 2891...
```

Three SYNs, retransmitted, and no SYN-ACK on the wire. The box received the
connection attempt and its answer did not come back this way.

## Your objective

Make network B's client reach the service, with the reply leaving by the uplink
the request arrived on. Both uplinks stay up and addressed. Do not break
network A.

## What you're being graded on

Both uplinks still up with their addresses, `ip route get` selecting `up-a` for
A's client and `up-b` for B's, and both clients fetching the page.

<details>
<summary>Hint 1 — the reply is a routing decision, not a reversal</summary>

A reply is not sent back the way the request came. The kernel does not remember
the inbound interface for a routed packet. It takes the destination address —
the client's address — and performs a fresh lookup, exactly as if the box had
started the conversation.

So the question is not "what happened to B's uplink". It is: which route does
this box use to reach `10.20.0.20`?

</details>

<details>
<summary>Hint 2 — look at the whole table</summary>

```
$ ip route show
default via 192.168.10.1 dev up-a metric 100
default via 192.168.20.1 dev up-b metric 200
192.168.10.0/24 dev up-a proto kernel scope link src 192.168.10.2
192.168.20.0/24 dev up-b proto kernel scope link src 192.168.20.2
```

There is no route to `10.20.0.20` and no route to `10.10.0.10`. Both clients are
off-link, so both are reached by a default route — and there are two.

```
$ ip route get 10.20.0.20
```

</details>

<details>
<summary>Hint 3 — what the metric is for</summary>

Both default routes have the same prefix length: `/0`. Longest-prefix match
cannot separate them, so the tie goes to the metric, and the lower number wins.
`up-a` at 100 beats `up-b` at 200 and takes **everything** — including replies
to a client that has never been anywhere near network A.

Two default routes do not mean two paths in use. It means one path in use and
one in reserve.

</details>

## Why the reply vanishes

The reply to `10.20.0.20` leaves by `up-a` and is handed to `192.168.10.1`,
network A's gateway. That gateway has no route to `10.20.0.20` — it is another
provider's customer — so it drops the packet.

It drops it quietly. There is no ICMP unreachable coming back to you, because
transit providers do not helpfully diagnose their customers' routing mistakes,
and even if one did, the message would arrive at a box that is not waiting for
it. From the box's point of view nothing failed. It routed a packet. Something
downstream discarded it.

This is **asymmetric routing**: the request comes in one interface and the reply
leaves by another. Sometimes it works — if both paths reach the client, you get
a connection that is merely strange. Here the second path does not reach the
client at all, so it does not work, and the failure looks like the far side is
ignoring you.

The tell is in the capture: repeated SYNs on `up-b` and no SYN-ACK. The box
*did* answer. The answer went somewhere else.

## The fix

<details>
<summary>Solution</summary>

Give each network a route of its own, more specific than either default:

```
$ ip route add 10.10.0.0/16 via 192.168.10.1 dev up-a
$ ip route add 10.20.0.0/16 via 192.168.20.1 dev up-b
```

A `/16` beats a `/0` regardless of metric, so each client is now reached through
the uplink it lives behind, and the reply path matches the request path.

Network A's route is added even though A already worked. It worked by accident —
it happened to be behind the uplink that won the metric tie. Leaving that
implicit means the day someone reweights the defaults, or an uplink flaps and
comes back with a different metric, A breaks the same way B did and for a reason
nobody will connect to the change.

Say what you mean in the routing table. A route that is currently redundant and
states an intention is worth more than a route that is currently correct by
coincidence.

</details>

## What not to do

**Delete one of the default routes.** It "fixes" the ambiguity by removing the
uplink from service. Now one of the two networks you are paying for carries
nothing, and the first outage on the survivor takes the box off the internet.

**Bind the service to a specific address.** The service was never the problem —
it answered. The answer was misrouted after it left the socket.

**Turn off `rp_filter`.** This comes up whenever the words "asymmetric routing"
appear, and it is aimed at the wrong direction. Reverse-path filtering drops
*inbound* packets whose source does not match the return route. Here the inbound
packets were accepted; it is the outbound reply that went astray. Loosening
`rp_filter` changes nothing except your exposure.

## Carrying this forward

Two rules, in order, decide every route lookup:

1. **Longest prefix wins.** A `/24` beats a `/16` beats a `/0`, always.
2. **Metric breaks ties between equal prefixes only.** It never lets a shorter
   prefix win.

When a multi-homed box is reachable on one interface and not another, check the
*return* route before anything else — the inbound path is rarely the fault, and
`ip route get <client-address>` answers it in one line.

The next lesson keeps the routing correct and breaks the translation instead: a
service that everyone can reach except the host it runs on.
