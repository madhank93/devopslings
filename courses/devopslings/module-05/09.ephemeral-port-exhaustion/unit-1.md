---
title: "the load generator runs out of ports and blames the server"
---

## The situation

The rates load test has started failing. Same code as last quarter, same server,
same box:

```
$ loadgen 400
ok=199 failed=201
first failure at request 200: [Errno 99] Cannot assign requested address
```

Two hundred requests succeed. Everything after that fails, instantly. The
obvious suspect is the server at `10.92.0.9:8080`, and while the load test is
failing it answers by hand without hesitating:

```
$ curl -s http://10.92.0.9:8080/rate
rate=1.0034
```

No refusals. No resets. Nothing in its journal. The accept queue is empty and
the process is idle.

## The error names the culprit

`Cannot assign requested address` — `EADDRNOTAVAIL`, errno 99 — is not a network
error. It never left the box. It is the local kernel refusing to start the
connection, because `connect()` on an unbound socket has to pick a **source
port** first, and there was not one to pick.

Compare it with the two errors it gets confused with:

| Error | Who said it | What happened |
|---|---|---|
| `Connection refused` (ECONNREFUSED) | the far end | a RST came back — nothing listening |
| `Connection timed out` (ETIMEDOUT) | your kernel, later | packets went out, nothing came back |
| `Cannot assign requested address` (EADDRNOTAVAIL) | your kernel, immediately | no packet was ever sent |

Only the third one is about *you*. The failures arrived in microseconds, which
is the tell: a timeout takes seconds, a refusal takes a round trip, and running
out of local resources takes no time at all.

## Where the ports went

Two facts, and the arithmetic between them.

```
$ sysctl net.ipv4.ip_local_port_range
net.ipv4.ip_local_port_range = 32768	32967
```

That is the ephemeral range this box picks source ports from: 200 of them. Every
outbound connection with no explicit `bind()` takes one.

```
$ ss -tan state time-wait dst 10.92.0.9 | head -4
Recv-Q Send-Q Local Address:Port  Peer Address:Port
0      0          10.92.0.1:32826    10.92.0.9:8080
0      0          10.92.0.1:32828    10.92.0.9:8080
0      0          10.92.0.1:32840    10.92.0.9:8080

$ ss -tan state time-wait dst 10.92.0.9 | wc -l
201
```

Two hundred sockets, all closed, none of them doing anything — and every one of
them still holding a port. The run opened connections until the range was gone,
and the `connect()` after that had nothing left to pick from.

## TIME_WAIT, and which end pays for it

When a TCP connection closes, one side sends the first FIN. That side — the one
that **initiated** the close — keeps the socket in `TIME_WAIT` for 2×MSL,
**60 seconds** on Linux, and it holds the local port for that whole time.

The other side goes to `CLOSED` immediately and pays nothing.

So the question that decides where the problem is: who hangs up first?

```
$ ss -tan state time-wait dst 10.92.0.9 | wc -l     # this box
201
$ ip netns exec svc ss -tan state time-wait | wc -l  # the server
1
```

All of it is here. The server speaks HTTP/1.1 and keeps connections open, as
HTTP/1.1 does by default; the generator finishes reading each response and calls
`close()`. The client closes first, so the client holds TIME_WAIT, so the client
runs out of ports while the server sits there with an empty socket table
wondering what all the fuss is.

Reverse it — a server that answers `Connection: close` — and the *server*
accumulates TIME_WAIT. That is the same mechanism producing a completely
different-looking outage, and it is why "who closes first" is the first question
to ask about any TIME_WAIT pile-up.

**Why TIME_WAIT exists at all**, briefly, because it is not arbitrary: a
duplicate segment from the old connection could arrive late and land in a new
connection that reused the same four-tuple. Holding the tuple for two maximum
segment lifetimes guarantees the stragglers are dead first. It is also what
allows the final ACK to be retransmitted if it is lost. The socket is not
leaking; it is doing its job.

## The arithmetic that predicts this

```
sustainable connections/second  =  ports available / 60
```

With 200 ports: about **3 per second**. With the Linux default range of
32768–60999 — 28,232 ports — about 470 per second, to a single destination.

That last clause matters. The uniqueness constraint is the four-tuple *(source
IP, source port, destination IP, destination port)*, so the limit is per
destination, not per box: 470/s to `10.92.0.9:8080` and another 470/s to
something else. Which is exactly why this failure hits the box that talks to one
backend hard — a load generator, a service mesh sidecar, a SNAT gateway — and
almost never a box with diverse traffic.

## Your objective

Three things.

1. Make the same run complete cleanly:

   ```
   $ loadgen 400
   ok=400 failed=0
   ```

   `/opt/load/loadgen.py` is shipped and checksummed. `/etc/loadgen.conf` is
   yours.

2. Leave the service alone. It must still answer on `10.92.0.9:8080`.

3. Write `/root/answers/ports.md`, exactly two lines:

   ```
   connect_error: <what connect() actually said, in words>
   who_holds_time_wait: <client or server>
   ```

## What you're being graded on

The full run completing with no failures, the generator unedited, the rates API
still answering, and both answers. Note that grading waits for the previous run's
sockets to retire before it starts — after an exhausted range, this box cannot
open a connection to anything for up to a minute, and that includes the checks.

<details>
<summary>Hint 1 — count what is holding the ports</summary>

```
$ ss -tan state time-wait dst 10.92.0.9 | wc -l
$ ss -s
$ sysctl net.ipv4.ip_local_port_range
```

Run the first one during a failing test and immediately after it. Then divide
the range size by 60 and compare it with how fast the generator opens
connections.

</details>

<details>
<summary>Hint 2 — three levers, in order of how much they fix</summary>

- **Stop needing a port per request.** The generator opens a new connection for
  every one of the 400. `/etc/loadgen.conf` has a knob for that, and it turns 400
  ports into one.
- **Give the box more ports.** `net.ipv4.ip_local_port_range` is 200 wide, which
  is a strange thing for a box that generates load. The Linux default is
  `32768 60999`.
- **Let the kernel take TIME_WAIT sockets back.** `net.ipv4.tcp_tw_reuse=1` —
  read the next hint before reaching for this one.

</details>

<details>
<summary>Hint 3 — on tcp_tw_reuse, which is the internet's favourite answer</summary>

`tcp_tw_reuse=1` lets a *new outbound* connection take over a TIME_WAIT socket
when TCP timestamps make it safe. It is a real fix for a steady drip of
connections. It will not rescue this run, and it is worth seeing why:

the kernel only reuses a TIME_WAIT socket that is **more than one second old**,
and this entire run finishes inside a second. Nothing in the range is old enough
to reclaim.

Two more, so you can dismiss them properly:

- **`tcp_tw_recycle` does not exist.** It was removed in Linux 4.12 because it
  broke every client behind NAT. Any advice that mentions it predates 2017.
- **`SO_REUSEADDR` is a different thing.** It lets a *listener* bind a port that
  is in TIME_WAIT. It does nothing for outbound connections.

</details>

## What actually happened

Nobody set out to break this. The port range was narrowed by a hardening
baseline — a small range is easier to allow through a firewall — and the load
test opened connections faster than 60-second sockets could retire. The two
facts were fine separately and hostile together, and the failure only appeared
once the run got long enough to lap the range.

The reason it presents as a server problem is that the client's error message is
the only evidence, and every instinct says an error about connecting is an error
about the thing being connected to. It is not. The server never heard about the
201st request.

<details>
<summary>Solution</summary>

Stop spending a port per request:

```
$ sed -i 's/^keepalive=no/keepalive=yes/' /etc/loadgen.conf
$ loadgen 400
ok=400 failed=0

$ ss -tan state time-wait dst 10.92.0.9 | wc -l
1
```

One connection, four hundred requests, one port. Keep-alive is not a tuning
trick here — it is the thing HTTP/1.1 was designed to do, and opening a fresh
connection per request also pays a handshake every time.

The range is worth widening as well, because a box that generates load has no
business with 200 ports:

```
$ sysctl -w net.ipv4.ip_local_port_range="32768 60999"
```

That alone also makes this particular run pass. It buys headroom rather than
fixing the appetite: at 400 connections it is fine, at 40,000 the same failure
comes back.

```
connect_error: cannot assign requested address
who_holds_time_wait: client
```

</details>

## Carrying this forward

- **`EADDRNOTAVAIL` is always local.** It means your own kernel had no source
  port. No amount of looking at the server will explain it.
- **TIME_WAIT belongs to whoever closed first.** Find that end before tuning
  anything; it decides whether you are fixing the client or the server.
- **Connection reuse beats every kernel knob.** A pool or keep-alive turns
  thousands of ports into a handful, removes the handshake, and needs no sysctl
  on any box that ever runs the code.
- **Do the division.** `ports / 60` is the sustainable connect rate to one
  destination. If your peak rate is above it, you have a date with this error.
- **The classic sightings** are a SNAT gateway or NAT device (every connection
  through it shares one source IP, so the whole estate shares one 28k range), a
  sidecar proxy talking to one upstream, and a health checker with a 1-second
  interval and no keep-alive.

The next lesson stops breaking things that were already running and asks you to
change one on purpose, on a box you are logged into: turning off SSH password
authentication without ending the session you are doing it from.
