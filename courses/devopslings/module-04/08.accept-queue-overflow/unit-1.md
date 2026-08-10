---
title: "clients time out and the server's log is empty"
---

## The situation

Clients report connection timeouts under load. The application log for that
window is not full of errors — it is empty. Nothing. As if the requests were
never made.

That emptiness is the most useful fact available, and it is usually read as the
least useful. The application cannot log a connection it was never given. So
whatever went wrong, went wrong before `accept()` returned — which means it
happened in the kernel, on the application's behalf.

```
$ /opt/queue/load.py 100
connected=5 failed=95
```

Ninety-five clients could not connect to a listening socket on a box with no
load worth mentioning.

## Your objective

Make all 100 connections succeed with no overflows counted. Two numbers cap the
queue and the smaller one wins. Do not make the worker faster — it stands in for
a busy application, and a real one will not speed up because you asked.

## What you're being graded on

`somaxconn` at least 128, the config's backlog at least 128, the *running*
listener showing the larger limit, the accept loop unchanged, and 100 clients
connecting with zero listen overflows.

<details>
<summary>Hint 1 — the kernel counted what the application could not</summary>

```
$ nstat -az | grep -E 'ListenOverflows|ListenDrops'
TcpExtListenOverflows   95
TcpExtListenDrops       95
```

Ninety-five. The same number that failed. The kernel knew exactly what happened
and wrote it to a counter that nothing scrapes and no dashboard shows.

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

Recv-Q is at Send-Q. The queue is full, and it is four deep.

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
counted as `TcpExtTCPReqQDrop` and is what SYN floods target.

**The accept queue** (fully established, waiting for the application). The
handshake is complete. The kernel is holding a working connection that nobody has
picked up. Sized by `min(listen() backlog, net.core.somaxconn)`. Overflow here is
`TcpExtListenOverflows`.

This lesson is entirely the second one. The handshake succeeded. The connection
existed. It was thrown away because there was nowhere to put it.

## Why the client sees a timeout

When the accept queue is full, the default behaviour is to **drop the ACK
silently** — `tcp_abort_on_overflow=0`. The client believes the handshake
completed, because from its side it did. It sends its request into a connection
the server has no record of, gets nothing back, retransmits, and eventually times
out.

Setting `tcp_abort_on_overflow=1` sends a RST instead, so clients fail fast. That
sounds better and usually is not: it converts a brief burst that would have
drained in milliseconds into a wall of hard errors. The default is a deliberate
bet that most overflows are transient.

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
almost never the network. `ListenOverflows`, `ListenDrops`, `TCPReqQDrop` and
`PruneCalled` each name a specific mechanism, and the counter is already there.

**Look for the second cap.** `min(app, kernel)` is a recurring shape: backlog and
`somaxconn`, `RLIMIT_NOFILE` and `fs.file-max`, a pool size and
`max_connections`. Fixing one of a pair changes nothing and looks like it should
have.
