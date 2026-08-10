---
title: "the pooled connection both ends still believe in"
---

## The situation

The checkout service keeps a pool of connections to its backend. After a quiet
period, the first request on a borrowed connection fails. A retry opens a fresh
connection and works, so the error rate is low, the graph is boring, and nobody
can reproduce it on demand.

Reproduce it on demand:

```
$ ip netns exec pool-client /opt/pool/probe.py 25
idle=25 outcome=FAILED after=10.0s error=timed out
```

Borrow a connection, hold it 25 seconds, use it. It dies. And while it is dying,
both ends are certain it is fine:

```
$ ip netns exec pool-client ss -tn
ESTAB  0  0  10.66.0.2:39714  10.66.1.5:9000

$ ip netns exec pool-svc ss -tn
ESTAB  0  0  10.66.1.5:9000   10.66.0.2:39714
```

Neither end is lying. TCP has no heartbeat of its own. An idle connection is
indistinguishable from a healthy one, because an idle connection *is* a healthy
one as far as the protocol is concerned — the state is local, and nothing on the
wire is required to maintain it.

Something between them disagrees, and it has no way to say so.

## Your objective

Make the 25-second probe succeed, without opening a new connection and without
shortening the idle period. Both the application and the kernel have a part in
this; fixing one and not the other still fails.

## What you're being graded on

Keepalive enabled in `/etc/pool.conf`, `tcp_keepalive_time` under the middlebox's
timeout *in the pool-client namespace*, the middlebox left exactly as it was, and
the 25-second probe returning `pooled-ok-2026`.

<details>
<summary>Hint 1 — find out when it dies, not that it dies</summary>

```
$ for t in 5 10 14 16 20; do ip netns exec pool-client /opt/pool/probe.py $t; done
```

There is a cliff. Find which side of it you are on, and you have found somebody's
configured timeout.

</details>

<details>
<summary>Hint 2 — watch the death</summary>

```
$ tcpdump -i to-client -nn 'tcp port 9000'
...
10.66.0.2.39714 > 10.66.1.5.9000: Flags [P.], seq 8:16, ack 16, length 8
10.66.0.2.39714 > 10.66.1.5.9000: Flags [P.], seq 8:16, ack 16, length 8
10.66.0.2.39714 > 10.66.1.5.9000: Flags [P.], seq 8:16, ack 16, length 8
```

The same segment, again and again. Nothing comes back — no ACK, no RST, no ICMP.

A reset would mean somebody made a decision and told you. Silence means somebody
made a decision and did not.

</details>

<details>
<summary>Hint 3 — two halves</summary>

The kernel has a mechanism for exactly this. It has been switched off since 1989:

```
$ sysctl net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_time = 7200
```

Two hours, and even that only applies to sockets that asked for keepalives —
which is off by default, per socket, and has to be set by the application.

Also: which network namespace is the application running in?

</details>

## What is actually happening

The box between the two ends is a stateful firewall. It forwards packets
belonging to flows it knows about and drops everything else. It learns a flow
from the SYN and forgets it after a period of silence:

```
$ sysctl net.netfilter.nf_conntrack_tcp_timeout_established
net.netfilter.nf_conntrack_tcp_timeout_established = 15
```

Fifteen seconds here for teaching. In production this is a NAT gateway at 350
seconds, a cloud load balancer at 350, a corporate firewall at 3600, or a mobile
carrier's NAT at 30 — and the number is rarely written down anywhere the
application team can find it.

When the entry expires, nothing is sent. There is no packet that means "I have
forgotten you". The next data packet arrives at a device with no matching flow,
gets dropped, and TCP does what TCP does with an unacknowledged segment: it
retransmits, backing off, for minutes, until the application's own timeout
fires.

That is why the failure is always on *use* and never on *idle*, and why it
always looks like the far end went away.

## The fix

<details>
<summary>Solution</summary>

Two halves, and either alone does nothing.

**The application asks for keepalives:**

```
$ sed 's/^keepalive=off/keepalive=on/' /etc/pool.conf > /tmp/pool.conf.new
$ cat /tmp/pool.conf.new > /etc/pool.conf
```

`SO_KEEPALIVE` is off by default on every TCP socket ever created. Until it is
set, the kernel timers below govern nothing.

**The kernel sends them often enough — in the right namespace:**

```
$ ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_time=5
$ ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_intvl=3
$ ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_probes=3
```

Five seconds is chosen to sit comfortably under the middlebox's fifteen. A
keepalive that arrives after the flow has been forgotten is just another packet
to drop.

`net.ipv4.*` sysctls are per network namespace. The process lives in
`pool-client`, so setting them on the box would change nothing and look
identical to having done the work.

</details>

## The distinction the title is about

These two are constantly confused, and they do opposite jobs:

|  | kernel TCP keepalive | middlebox idle timeout |
|---|---|---|
| Whose | yours | somebody else's |
| Default | off per socket, 7200 s | 30–3600 s, always on |
| Announced | no | no |
| Purpose | notice a dead peer | reclaim state |
| You can change it | yes | usually not |

The keepalive interval must be **shorter** than the idle timeout, and the entire
point is not to detect the failure faster — it is to stop the failure happening.
Traffic on the flow, even one empty segment, resets the middlebox's timer.

Set it too long and you detect deaths you caused. Set it far too short and you
are paying for packets to keep idle connections that a pool should probably have
closed.

## What not to do

**Raise the middlebox's timeout.** In production that box belongs to the network
team, sits between you and a dozen other services, and its timeout is not yours.
Survive it.

**Retry once and move on.** This is what most pools already do, and it is why
the bug survived to reach you: it converts a persistent misconfiguration into a
low background error rate that everyone learns to ignore.

**Set the pool's own idle-eviction below the timeout.** This one is a legitimate
second answer — close connections before the middlebox forgets them. It works,
it costs a reconnect per idle period, and it still needs you to know the number.

## Carrying this forward

**An ESTABLISHED socket on both ends proves nothing.** The state is local. Only
a packet that made it across proves the path exists.

**Silence is diagnostic.** A reset means a machine refused you. Silence means a
machine forgot you. Repeated identical segments with no reply is the signature —
you will see it again in the capture lesson.

**Ask which namespace a sysctl applies to.** `net.ipv4.*` and `net.netfilter.*`
are per-namespace. Setting one on the host and expecting it to reach a container
is the same mistake as setting it on the box here.
