---
title: "every metric was sent, and the dashboard counts one in twenty"
---

## The situation

The checkout service sends one counter per request to the metrics collector on
this box, over UDP port 8125. At 9am a batch job fires about 8000 requests in
under a second. The load balancer logs all 8000, and the dashboard shows a few
hundred.

```
$ curl -s http://127.0.0.1:9102/
collector_received_total 0
$ send-burst
sent 8000 counters, 0 send errors
$ sleep 3; curl -s http://127.0.0.1:9102/
collector_received_total 369
```

Every send succeeded. The collector is running and logged nothing. Someone has
already been here before you, too, because its config asks for a big buffer:

```
$ cat /etc/collector/collector.conf
[listen]
port = 8125
# Sized for peak: the 9am batch fires ~8k counters in well under a second.
rcvbuf_bytes = 8388608
```

## Your objective

Make the collector receive all 8000 counters of a burst, and keep it that way
after a reboot. Don't edit the collector's code. Switching the app to TCP is a
project, not a fix.

## What you're being graded on

A replayed burst arrives whole, all 8000, counted by the collector itself. The
setting that makes it possible is applied at boot, not just in the running
kernel.

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
	 skmem:(r0,rb425984,t0,tb229376,f4096,w0,o336,bl0,d7581)
```

`rb` is the receive buffer, and `d` counts drops on this socket. The config
asked for 8388608.

</details>

<details>
<summary>Hint 3: the ceiling nobody mentions</summary>

`setsockopt(SO_RCVBUF)` is a request. The kernel caps it at
`net.core.rmem_max` without returning an error, and then doubles the result to
cover its own bookkeeping. `425984` is `212992 × 2`.

```
$ sysctl net.core.rmem_max
net.core.rmem_max = 212992
```

</details>

## Why it is silent

A burst is a few thousand datagrams in tens of milliseconds. The collector reads
about five thousand a second, because parsing, tagging and aggregating aren't
free. So for a moment the arrivals outrun the reader, and the receive queue is
what's supposed to absorb the difference. That's exactly what the 8 MB in the
config was sized for.

The kernel quietly reduced that request to 208 KB, a few hundred datagrams'
worth. The rest of the burst arrived to a full queue and was thrown away. The
sender returned success every time, and the collector never saw what it never
received. The application never knew to log anything, so the only record is a
kernel counter.

This is the normal failure mode of UDP. It isn't loss on the wire. The packets
crossed the network fine and were dropped at the last step, on the receiving
host, because the reader was slower than the burst.

## The fix

<details>
<summary>Solution</summary>

Raise the ceiling so the request is honoured, persistently, then restart the
collector, because a socket's buffer is sized when it's created:

```
$ echo 'net.core.rmem_max = 8388608' > /etc/sysctl.d/60-udp-collector.conf
$ sysctl --load /etc/sysctl.d/60-udp-collector.conf
$ systemctl restart metrics-collector.service
$ ss -ulmn 'sport = :8125' | grep -o 'rb[0-9]*'
rb16777216
$ send-burst; sleep 3; curl -s http://127.0.0.1:9102/
collector_received_total 8000
```

</details>

## What not to do

**Raise `rcvbuf_bytes` in the config.** Ask for 64 MB and you still get the
same 208 KB, because the cap applies to every request.

**Raise `net.core.rmem_default`.** That's the size a socket gets when it asks
for nothing. This one asks explicitly, so the default never applies to it.

**`sysctl -w` and stop.** The running kernel has the new ceiling, and the next
boot puts back the old one. The collector restarts with a small buffer and the
loss returns with no change anyone remembers.

**Raise the ceiling without restarting the collector.** The existing socket
keeps the buffer it was given at creation, so nothing changes until it's
re-created.

**Make the collector faster.** It would help, but the code isn't yours, and
there's always a burst bigger than the reader. The queue exists to absorb it,
so size the queue to the burst.

## Carrying this forward

For any UDP service (metrics, syslog, DNS, video, game traffic), "the sender
succeeded" isn't evidence of delivery. Before blaming the network, check the
receiving host: `nstat -az UdpRcvbufErrors` system-wide, and `ss -ulmn` per
socket. `rb` shows what the socket actually got and `d` shows what it lost.

Whenever an application asks the kernel for a resource, check what it got
rather than what it asked for. The kernel caps some requests without saying
so.
