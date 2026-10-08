---
title: "clients time out and the server's log is empty"
---

## The situation

Clients report connection timeouts under load. The application log for that
window is not full of errors — it is empty. Nothing. As if the requests were
never made.

That emptiness is the most useful fact available, and it is usually read as the
least useful.

```
$ /opt/queue/load.py 100
connected=64 failed=36
```

A hundred clients arriving together, and a third of them could not connect to a
listening socket on a box with no load worth mentioning. The split moves from
run to run; the failures do not go away.

## Your objective

Make all 100 connections succeed with no overflows counted. Do not make the
worker faster — it stands in for a busy application, and a real one will not
speed up because you asked.

## What you're being graded on

100 simultaneous clients connecting with zero listen overflows, against the
same slow accept loop — and every limit on the listener's queue at least 128, as
read back from the running process, not only from the files that configure it.

<details>
<summary>Hint 1 — the kernel counted what the application could not</summary>

```
$ nstat -az | grep -E 'ListenOverflows|ListenDrops'
TcpExtListenOverflows   312
TcpExtListenDrops       312
```

More than there were clients: every retried SYN that found the queue full was
counted again. The kernel knew exactly what happened and wrote it to a counter
that nothing scrapes and no dashboard shows. The application cannot log a
connection it was never given.

</details>

<details>
<summary>Hint 2 — the two columns mean something else here</summary>

```
$ ss -lnt 'sport = :9200'
State   Recv-Q  Send-Q  Local Address:Port
LISTEN  5       4          127.0.0.1:9200
```

On a LISTEN socket these are not bytes.

- **Recv-Q** — completed connections waiting for the application to accept them
- **Send-Q** — the maximum the queue can hold

Recv-Q is past Send-Q — the kernel holds one more than the limit before it
calls the queue full. The queue is full, and it is four deep.

</details>

<details>
<summary>Hint 3 — where does 4 come from, and what caps it?</summary>

```
$ grep backlog /etc/queue.conf
backlog=4

$ sysctl net.core.somaxconn
net.core.somaxconn = 8
```

The application asks for a backlog. The kernel grants `min(that, somaxconn)`.
Raise one and the other still holds you down.

And one more thing: when is that number read?

</details>

## The two queues

A listening socket has two, and confusing them costs an afternoon.

**The SYN queue** (half-open). A SYN arrives, the kernel replies SYN-ACK and
waits for the final ACK. Sized by `tcp_max_syn_backlog`. Overflow here is
counted as `TcpExtTCPReqQFullDrop` (or `TCPReqQFullDoCookies` when SYN cookies
step in) and is what SYN floods target.

**The accept queue** (fully established, waiting for the application). The
handshake is complete. The kernel is holding a working connection that nobody has
picked up. Sized by `min(listen() backlog, net.core.somaxconn)`. Overflow here is
`TcpExtListenOverflows`.

This lesson is entirely the second one. It was full, and a full accept queue
throws work away at both ends of the handshake.

## Why the client sees a timeout

While the accept queue is full, the kernel **drops new SYNs silently**. The
client retransmits — at one-second intervals on a current kernel, backing off
after that — and if the queue has not drained before its connect timeout, it
gives up. Every dropped SYN adds one to `ListenOverflows`.

A handshake that was already under way when the queue filled fails differently:
the client's final ACK is dropped (`tcp_abort_on_overflow=0`, the default). The
client believes it is connected, because from its side it is, sends its request
into a connection the server has no record of, and times out on the read
instead.

Setting `tcp_abort_on_overflow=1` answers that second case with a RST, so
clients fail fast. That sounds better and usually is not: it converts a brief
burst that would have drained in milliseconds into a wall of hard errors. The
default is a deliberate bet that most overflows are transient.

Either way the application never hears about it. There is no callback for "a
connection was made for you and discarded".

## The fix

<details>
<summary>Solution</summary>

Both numbers, then a restart:

```
$ sysctl -w net.core.somaxconn=1024

$ sed 's/^backlog=4/backlog=512/' /etc/queue.conf > /tmp/queue.conf.new
$ cat /tmp/queue.conf.new > /etc/queue.conf

$ systemctl restart queue-app.service
```

Raise `somaxconn` first, so the restart picks up a ceiling that is already in
place.

The restart is not ceremony. `listen()` takes its backlog **once**, at the moment
it is called. An edited config with no restart is a change that has visibly been
made and has had no effect — and `ss -lnt` will tell you so, because Send-Q still
shows the old number.

```
$ ss -lnt 'sport = :9200'
LISTEN  0  512  127.0.0.1:9200
```

</details>

## What a queue does and does not buy

A deeper queue buys **time**, not throughput. It absorbs a burst so the worker
can catch up.

If the worker is permanently slower than arrivals, a deeper queue makes things
worse: connections sit in it for longer, clients time out while queued, and the
server does work for callers who have already given up. That is bufferbloat with
different units.

The honest reading of a persistently full accept queue is that the application is
under-provisioned. The queue is the shock absorber, not the engine.

## Carrying this forward

**An empty application log during an outage is evidence.** It narrows the fault
to everything that happens before the application is involved: the accept queue,
the listener's address, the firewall, the route.

**`nstat -az` is the first command for "the network is dropping packets".** It is
almost never the network. `ListenOverflows`, `ListenDrops`, `TCPReqQFullDrop` and
`PruneCalled` each name a specific mechanism, and the counter is already there.

**Look for the second cap.** `min(app, kernel)` is a recurring shape: backlog and
`somaxconn`, `RLIMIT_NOFILE` and `fs.file-max`, a pool size and
`max_connections`. Fixing one of a pair changes nothing and looks like it should
have.
