---
title: "every metric was sent, and the dashboard comes up a sixth short"
---

## The situation

The checkout service sends one counter per request to the metrics collector on
this box, over UDP port 8125. At 9am a batch job fires about 8000 requests in
a second. The load balancer logs all 8000. The dashboard is short by a sixth,
and the shortfall varies from run to run.

```
$ curl -s http://127.0.0.1:9102/
collector_received_total 0
$ send-burst
sent 8000 counters, 0 send errors
$ sleep 3; curl -s http://127.0.0.1:9102/
collector_received_total 6570
```

Every send succeeded. The collector is running and logged nothing. Its config:

```
$ cat /etc/collector/collector.conf
[listen]
port = 8125
# Trimmed in the memory diet (OPS-2231): the collector keeps up with
# traffic, so the queue only ever holds a handful of packets.
rcvbuf_bytes = 16384
```

## Your objective

Make the collector receive all 8000 counters of a burst, and keep it that way
when the collector or the box restarts. Don't edit the collector's code, and
don't slow down `send-burst`: it replays what the app really sends. Switching
the app to TCP is a project, not a fix.

## What you're being graded on

A replayed burst arrives whole, all 8000, counted by the collector itself, and
the kernel's `UdpRcvbufErrors` counter doesn't move while it does.

<details>
<summary>Hint 1: what "sent" means for UDP</summary>

A TCP `send()` puts bytes into a connection that the kernel will retransmit,
acknowledge and pace, slowing the sender down if the receiver falls behind. A
UDP `sendto()` hands one datagram to the kernel and returns. Success means the
packet left this socket. It doesn't mean anything arrived anywhere. UDP has no
acknowledgement, no retransmission and no backpressure.

So if the datagrams are lost, nobody is told. Nobody, that is, except a
counter:

```
$ nstat -az UdpRcvbufErrors
$ send-burst
$ nstat -az UdpRcvbufErrors
```

</details>

<details>
<summary>Hint 2: how big is the queue, really?</summary>

Each UDP socket has a receive queue in the kernel, sized in bytes. Datagrams wait
there until the application reads them. When it's full, the kernel discards
the next arrival and bumps `UdpRcvbufErrors`. Look at the socket the collector
actually has:

```
$ ss -ulmn 'sport = :8125'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
UNCONN 0      0            0.0.0.0:8125      0.0.0.0:*
	 skmem:(r0,rb32768,t0,tb229376,f4096,w0,o336,bl0,d1430)
```

`rb` is the receive buffer, and `d` counts drops on this socket. The kernel
doubles whatever `SO_RCVBUF` asks for to cover its own bookkeeping, so the
config's 16384 became 32768.

</details>

<details>
<summary>Hint 3: why it keeps up, until it doesn't</summary>

The collector reads far faster than 8000 a second, so most of the time the
queue is empty. But every 1000 counters it stops reading for about 20 ms to
flush its aggregates. At 8000 a second, that's about 160 datagrams arriving
while nobody reads.

A queued datagram costs much more than its 50 bytes of payload: the kernel
charges the whole buffer it sits in, about 1.2 KB here. Divide `rb` by that
and see how many fit.

</details>

## Why it is silent

The arrivals only outrun the reader for a moment, eight times a burst. The
receive queue is what's supposed to absorb that moment. At 32 KB it holds
about 28 datagrams, so each pause throws away the next hundred or so.

The sender returned success every time, and the collector never saw what it
never received. The application never knew to log anything, so the only record
is a kernel counter.

This is the normal failure mode of UDP. It isn't loss on the wire. The packets
crossed the network fine and were dropped at the last step, on the receiving
host, because for a moment the reader wasn't reading.

## The fix

<details>
<summary>Solution</summary>

Size the queue to the pause. About 160 datagrams at about 1.2 KB each is about
200 KB, so ask for 512 KB to leave headroom. Then restart the collector, because
a socket's buffer is sized when it's created:

```
$ sed -i 's/^rcvbuf_bytes = .*/rcvbuf_bytes = 524288/' /etc/collector/collector.conf
$ systemctl restart metrics-collector.service
$ ss -ulmn 'sport = :8125' | grep -o 'rb[0-9]*'
rb1048576
$ send-burst; sleep 3; curl -s http://127.0.0.1:9102/
collector_received_total 8000
```

The config is a file, so the fix survives a restart of either the collector or
the box.

</details>

## What not to do

**Raise `net.core.rmem_max`.** It is the ceiling on what `SO_RCVBUF` may
ask for, and the request here is far below it, so a higher ceiling changes
nothing. On a VM it's the knob you'd reach for when the app asks for more than
the ceiling allows. In a container it usually isn't yours. On Linux 6.11 and
later a container sees the host's value read-only, and older kernels don't show
it to a container at all. `sysctl -w` prints `Operation not permitted` and
**still exits 0**, so a script that trusts the exit status thinks it worked.
Read the value back, or better, read `rb` off the socket.

**Ask for a huge buffer and assume you got it.** The kernel caps the request
at that ceiling without returning an error. Here the ceiling is enough for the
pauses, but check `rb` rather than trusting the config.

**Raise `net.core.rmem_default`.** That's the size a socket gets when it asks
for nothing. This one asks explicitly, so the default never applies to it.

**Change the config without restarting the collector.** The existing socket
keeps the buffer it was given at creation, so nothing changes until it's
re-created.

**Make the collector faster.** The code isn't yours, and every reader pauses
sometime: a flush, a garbage collection, a busy CPU. The queue exists to absorb
the pauses, so size it to them.

## Carrying this forward

For any UDP service (metrics, syslog, DNS, video, game traffic), "the sender
succeeded" isn't evidence of delivery. Before blaming the network, check the
receiving host: `nstat -az UdpRcvbufErrors` system-wide, and `ss -ulmn` per
socket. `rb` shows what the socket actually got and `d` shows what it lost.

Whenever an application asks the kernel for a resource, check what it got
rather than what it asked for. The kernel caps some requests without saying
so, and `sysctl` can fail without saying so either.
