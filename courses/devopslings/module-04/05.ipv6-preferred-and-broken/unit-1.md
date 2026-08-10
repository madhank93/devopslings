---
title: "every request stalls for five seconds and then succeeds"
---

## The situation

Nothing is failing. Everything is slow by the same amount:

```
$ /opt/client/fetch.py
elapsed=5.02
dual-stack-2026
```

Five seconds, every request, every time. It was milliseconds last month.

A round number that never varies is not congestion, not load, and not a slow
disk. Real slowness is noisy. A constant means a timer expired, and somebody
chose that number in advance.

The obvious suspects are already ruled out:

```
$ time getent hosts app.internal
real  0m0.003s

$ time curl -s http://172.31.0.10:8080/ >/dev/null
real  0m0.004s
```

Resolution is instant. The service is instant. The five seconds are spent
between those two facts, and during them nothing appears on the wire.

## Your objective

Make the fetch complete in under two seconds.

Two answers the check refuses: turning IPv6 off on the box, and deleting the
AAAA record so the name is v4-only. Both make the symptom vanish. Neither is
defensible the day something reaches you over v6 only.

## What you're being graded on

`disable_ipv6` still 0, `app.internal` still resolving to a v6 address, that
address actually answering, and the fetch returning the page in under two
seconds.

<details>
<summary>Hint 1 — the name has more than one answer</summary>

```
$ getent ahosts app.internal
```

`getent hosts` shows you one line. Resolution returns a *list*, in a defined
order, and a client works down it.

</details>

<details>
<summary>Hint 2 — try each address by hand</summary>

```
$ time curl -s -m 6 "http://[fd00:dead:beef::99]:8080/"
real  0m6.001s

$ time curl -s -m 6 "http://172.31.0.10:8080/"
real  0m0.004s
```

One address works. The other does not fail — it *hangs*. That difference is the
entire lesson.

</details>

<details>
<summary>Hint 3 — hanging is worse than failing</summary>

```
$ ip -6 route get fd00:dead:beef::99
fd00:dead:beef::99 dev eth0 src fd00:51ee:9000::10
```

There is a route, so the kernel accepts the packet and sends it. Nothing answers.
The client waits out its own timeout before trying the next address.

With no route at all, the connect would fail instantly with `ENETUNREACH` and
the client would move to the v4 address in microseconds. The stale route is what
converts a wrong answer into a five-second one.

</details>

## Why IPv6 goes first

`getaddrinfo()` sorts its results by RFC 6724, and in the default policy table a
global IPv6 address outranks IPv4. So a dual-stack name is tried over v6 first —
correctly, by design, and every conforming client does it.

Most clients then walk the list one address at a time, giving each a full
connect timeout. A broken first entry costs that timeout on **every single
connection**, forever, with no error ever surfacing, because the fallback
eventually works.

`curl` is not a good witness here. Modern curl implements Happy Eyeballs: it
starts the v6 connect, waits about 200 ms, and races v4 alongside it. That turns
this five-second stall into a barely-visible blip — which is exactly why the
person who tested with `curl` reported that everything was fine.

## What actually broke

```
$ getent ahosts app.internal
fd00:dead:beef::99  STREAM app.internal
172.31.0.10         STREAM app.internal
```

The `fd00:dead:beef::/64` prefix was allocated and documented. The host never
got an address in it — it lives on `fd00:51ee:9000::/64`. The AAAA record was
published against the plan rather than against the machine, and the on-link
route for the planned prefix was left behind.

Nobody noticed, because IPv4 still worked and the only symptom was latency that
looked like someone else's problem.

## The fix

<details>
<summary>Solution</summary>

Point the record at the address the host actually holds, and clear the route
that made the wrong one hang:

```
$ sed 's|^fd00:dead:beef::99 |fd00:51ee:9000::10 |' /etc/hosts > /tmp/h
$ cat /tmp/h > /etc/hosts
$ ip -6 route del fd00:dead:beef::/64 dev eth0
```

(`/etc/hosts` is a bind mount inside a container, so it must be rewritten in
place. `sed -i` renames a temporary file over the target and the rename fails
with `Device or resource busy`.)

IPv6 is still enabled, the AAAA record still exists, and now it is true. The
fetch takes microseconds and goes over v6 — the protocol the client preferred
all along.

</details>

## Why the two forbidden answers are forbidden

**`disable_ipv6=1`.** Fixes it today by removing a protocol from the machine.
It will be reverted by the next reboot, image rebuild, or config-management
run, and the stall will come back with no connection to anything anyone changed.

**Deleting the AAAA record.** The same retreat one layer up, with the added
property that it is invisible: the host is now unreachable from any v6-only
client, and nothing reports that as an error.

Both treat "IPv6 is preferred" as the bug. It is not the bug. The bug is a
record that promised an address the host does not have.

## Carrying this forward

**A constant, round delay is a timeout, and timeouts have owners.** Five seconds,
three seconds, thirty seconds — find whose default it is and you have found the
layer.

**Resolve to a list, then try each address by hand.** `getent ahosts` and then a
direct connect to each entry localises this class of fault in two commands.

**Hanging beats failing only for the person who wrote the timeout.** A missing
route fails fast and fails over. A stale route succeeds at routing and fails at
arriving, which is the expensive kind.

**Test with the client you actually run.** Curl's Happy Eyeballs hides this; the
library in your application probably does not implement it.
