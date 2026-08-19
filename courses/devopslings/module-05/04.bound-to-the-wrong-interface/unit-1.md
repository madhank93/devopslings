---
title: "the service is up, the port is open, and the connection is refused"
---

## The situation

The orders API is healthy. On the box it runs on:

```
$ curl http://127.0.0.1:8080/
orders-canonical-2026
```

From the peer box, and from anything on the outside network, the same request
comes back refused — instantly, not after a timeout.

The ticket says firewall, because it always says firewall, and the firewall is
right there to be blamed:

```
$ nft list ruleset
table inet edge {
        chain input {
                type filter hook input priority 0; policy accept;
                tcp dport 8080 accept
                ct state established,related accept
        }
}
```

Port 8080 accepted. Policy accept. That ruleset is not refusing anything, and
you can spend an afternoon proving it.

## Instant refusal is a fact, not a symptom

Notice what the failure *is*. Not a hang. Not a timeout. An immediate refusal.

That distinction is the whole diagnosis, and it is the same one from the first
lesson in this module:

- **Dropped** — a firewall discarding packets produces silence. The client
  retries, backs off, and eventually times out. Seconds.
- **Refused** — a RST came back. Something received the packet, looked at it,
  and declined. Under a millisecond.

A refusal means the packet reached the machine and the kernel there had no
socket to hand it to. The firewall let it through. The routing worked. The box
answered — and its answer was "nothing here".

So the question is not "what is blocking this" but "why does this machine think
nothing is listening, when something obviously is".

## Your objective

Make the service answer on `172.31.0.10`, the box's address on the lab network,
while it still refuses on `203.0.113.1`, the box's address on the outside
network.

Constraints:

- **Leave the nftables ruleset alone.** It was never the problem.
- **Nothing in front of the service.** No socat, no port forwarding, no
  redirect. The listening socket itself has to move.
- **Binding to every interface is not the fix**, and the check rejects it. This
  box faces two networks and the service belongs on exactly one.

## What you're being graded on

A listener on `172.31.0.10:8080` that belongs to the orders service itself, the
page served from it, nothing listening on `0.0.0.0` or on `203.0.113.1`, and the
outside network still refused.

<details>
<summary>Hint 1 — ask what is listening, and where</summary>

```
$ ss -ltnp
```

`-l` listening, `-t` TCP, `-n` numeric, `-p` the process. Read the **Local
Address** column, not just the port. The port is 8080 in every case; the
address in front of it is the answer.

</details>

<details>
<summary>Hint 2 — that address is not a setting</summary>

```
LISTEN 0 5 127.0.0.1:8080 ... users:(("python3",pid=406,fd=3))
```

`127.0.0.1` is not "port 8080, restricted". It is the loopback interface — a
distinct network device that exists only inside this machine. A packet arriving
on `eth0` cannot be delivered to a socket bound to loopback, because the socket
is not on that interface at all.

This is why no firewall rule fixes it and no route fixes it. The socket is in a
place remote packets do not go.

</details>

<details>
<summary>Hint 3 — where is that address configured</summary>

The process is `python3 -m http.server`. Its bind address came from the command
line that started it, which came from the unit file:

```
$ systemctl cat svc-orders.service
```

Change it there, `daemon-reload`, and restart — and pick the address
deliberately, because `ip addr` will show you more than one to choose from.

</details>

## The rule

A TCP socket is bound to an **address**, not merely a port. That address selects
which interfaces can deliver to it:

| Bind address | Reachable from |
|---|---|
| `127.0.0.1` | this machine only, via loopback |
| `172.31.0.10` | the lab network, on that interface |
| `203.0.113.1` | the outside network, on that interface |
| `0.0.0.0` | every interface, present and future |

`0.0.0.0` is where this gets people. It resolves the incident in one word, and
it is a decision about exposure that nobody wrote down. On a box with one
interface it is indistinguishable from binding that interface. On a box with
two, it silently publishes the service on both — including the one facing
outward. The next interface added to the machine gets the service too, and no
one revisits the unit file.

Bind to the address you mean. `0.0.0.0` means "I have not thought about it".

## What actually happened

`--bind 127.0.0.1` is a sensible default and is usually right — it is how a
service says "only the reverse proxy on this box talks to me". This service was
developed that way, then deployed on a box where the client is on another
machine, and the flag came along unchanged.

Nothing logged an error, because nothing is wrong from the service's point of
view. It is listening exactly where it was told to listen. Every layer reports
success, which is this module's recurring shape: the route is fine, the firewall
is fine, the process is up, and the connection still fails.

<details>
<summary>Solution</summary>

```
$ sed -i 's|--bind 127.0.0.1|--bind 172.31.0.10|' /etc/systemd/system/svc-orders.service
$ systemctl daemon-reload
$ systemctl restart svc-orders.service

$ ss -ltnp 'sport = :8080'
LISTEN 0 5 172.31.0.10:8080 ... users:(("python3",...))

$ curl http://172.31.0.10:8080/
orders-canonical-2026
```

`daemon-reload` is not optional. Without it systemd restarts the service from
its cached copy of the unit and the change appears to do nothing — a minute of
confusion that has convinced many people the bind address was not the problem.

**Why not `0.0.0.0`:** it passes the "reachable from the peer" test and puts the
orders API on `203.0.113.1` at the same moment. The check rejects it for that
reason, and so should a review.

**Why not a relay:** `socat TCP-LISTEN:8080,bind=172.31.0.10 TCP:127.0.0.1:8080`
works. It serves the page. It also leaves the original socket exactly as wrong
as it was, adds a process with no supervision and no restart policy, and doubles
the number of things that must be running for the API to answer. The check looks
at which process owns the listener for this reason.

</details>

## Carrying this forward

When a service is refused from off-box, `ss -ltnp` before anything else. The
Local Address column answers it, and it answers in one line — before you have
read a single firewall rule.

Two habits worth keeping:

- **Refused and timed out are different diagnoses.** Refused means you reached
  the machine. Timed out means you did not. Never let a ticket flatten them into
  "can't connect".
- **`0.0.0.0` in a unit file deserves a comment** explaining why every interface
  is intended. Usually there is no such reason, and writing the comment is what
  makes that obvious.

The next lesson keeps the service correct and puts the firewall back in play for
real — with two dependencies failing in two different ways, where the difference
between the drop and the reject tells you which rule wrote it.
