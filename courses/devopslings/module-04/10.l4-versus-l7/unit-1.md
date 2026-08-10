---
title: "four requirements, one load balancer layer each"
---

## The situation

Four services, four load balancers to choose. L7 sees more, so L7 sounds like
the better default — and it is chosen by default far more often than it is
chosen on purpose.

The cases are in `/srv/reqs/`. Write a layer and a deciding constraint for each
into `/root/answers/verdict.md`:

```
case-1: layer=? because=?
case-2: layer=? because=?
case-3: layer=? because=?
case-4: layer=? because=?
```

`layer` is `l4` or `l7`. `because` is one of `termination`, `routing`,
`sourceaddress`, `throughput`, `protocol`.

One of the four is a case where L7 cannot do what is being asked at all, however
it is configured. Finding that one is most of the exercise.

## What you're being graded on

Four correct layers and four correct constraints. The constraint has to be the
one that actually decides — the one that would still decide if everything else
in the case changed.

## The difference that matters

**L4** forwards a TCP connection. It picks a backend from the addresses and
ports, and from then on it is moving bytes. It does not know what protocol is
inside and does not care.

**L7** *terminates* the client's connection, parses the protocol, and opens its
own separate connection to the backend. Two connections, not one.

Everything else follows from that sentence.

| | L4 | L7 |
|---|---|---|
| Connections | one, forwarded | two, one either side |
| Can route on | address, port | header, path, method, cookie |
| Can terminate TLS | no | yes |
| Backend sees source | the real client | the balancer |
| Understands your protocol | does not need to | must |
| Cost per connection | low | parse, buffer, re-encrypt |

<details>
<summary>Hint 1 — ask what the routing key is, and when it exists</summary>

For each case: what does the balancer need to look at to choose a backend, and
is that thing available at the moment it has to choose?

An L7 balancer chooses per request. An L4 balancer chooses once, at connection
time, and is committed.

</details>

<details>
<summary>Hint 2 — for each case, what does terminating cost you?</summary>

Terminating gives you visibility and takes three things: the client's source
address, the protocol's own end-to-end semantics, and throughput.

In two of these cases one of those costs is disqualifying.

</details>

<details>
<summary>Hint 3 — two cases share an answer for opposite reasons</summary>

Both are `protocol`, and they are not the same problem. In one, the balancer
cannot understand what is on the wire. In the other it understands perfectly
and the thing it would route on has not been sent yet.

</details>

## Working through them

**Case 1 — the checkout front end.** Several things here want L7: routing `/api/`
by path, adding a header. But those are preferences and could be moved elsewhere
— into the application, into a service mesh, into DNS.

One requirement cannot move. The certificate must terminate before traffic
reaches the application, because the application team may not hold the private
key. Only something that terminates TLS can do that, and terminating is the
definition of L7.

`layer=l7 because=termination`. Not `routing`: the path split is real, and it is
the second reason, not the deciding one.

**Case 2 — telemetry ingest.** A private binary framing protocol over long-lived
TCP. There are no requests and no headers. An L7 balancer would have nothing to
parse — no proxy on earth ships a module for a protocol invented in-house.

Note what is *not* the reason. 12 Gbit/s and 90,000 connections would be an
argument about cost. But even at one connection per hour, L7 still could not
route this, because there is nothing there to read.

`layer=l4 because=protocol`. `throughput` is a real consideration and a
distractor: it would matter if L7 were possible at all.

**Case 3 — the regulated internal service.** No TLS, no content routing, 200
requests/second. Nothing here needs L7 in the slightest.

And one thing rules it out. The application itself must log the true source
address. An L7 balancer opens its own connection, so the backend sees the
balancer's address — always, by construction.

The usual answer is `X-Forwarded-For`. The auditors explicitly rejected it, and
their reasoning is sound: a header is a claim made by whoever wrote it, and
trusting it means trusting every hop that could have set it. The connection's
source address is not a claim.

`layer=l4 because=sourceaddress`.

**Case 4 — the read replicas.** This is the one that cannot be done.

The wish is to route read-only transactions to replicas and everything else to
the primary. The balancer would have to know, at the moment it picks a backend,
whether the traffic is read-only. It cannot: read-only-ness is a property of
statements sent later, inside a connection that carries many transactions over
its life.

Even a balancer that fully understood the PostgreSQL wire protocol could not do
this, because a connection is not a transaction. Routing per connection is the
only thing available, and the requirement is per transaction.

`layer=l4 because=protocol` — the same token as case 2, the opposite reason. In
case 2 the protocol is opaque. Here it is entirely legible and the routing key
does not exist yet.

The real answer to case 4 lives in the application or in a connection pooler that
understands transactions — two connection pools, one per role. Not in a load
balancer.

## Solving it

<details>
<summary>Solution</summary>

```
case-1: layer=l7 because=termination
case-2: layer=l4 because=protocol
case-3: layer=l4 because=sourceaddress
case-4: layer=l4 because=protocol
```

</details>

## What about PROXY protocol, and TLS passthrough?

Two things that blur the line, and both are worth knowing:

**PROXY protocol** prepends the original source address to the connection, so an
L7 balancer can pass it to a backend that understands the preamble. It is a
better answer than `X-Forwarded-For` because it is not part of the application
protocol and cannot be spoofed by the client. It would not satisfy case 3's
auditors either — the backend is still trusting something the balancer said — but
it is what to reach for when the requirement is "log the client IP" rather than
"the connection must be the client's".

**TLS passthrough / SNI routing** lets an L4 balancer read the SNI field from the
unencrypted ClientHello and pick a backend by hostname, without terminating. It
is genuinely useful and it is still L4 — one connection, no decryption, no
per-request routing.

## Carrying this forward

Three questions decide this every time:

1. **What is the routing key, and does it exist when the decision must be made?**
   Per-connection facts are available to L4. Per-request facts need L7. Facts
   that arrive later than the decision are available to neither.
2. **Does anything require the connection to end at the balancer?** Key custody,
   header rewriting, response caching. If yes, L7 — and accept the costs.
3. **Does anything require the connection to survive intact?** Source address,
   end-to-end TLS, a protocol nobody else parses. If yes, L4.

When 2 and 3 are both yes, no load balancer resolves it and the design has to
change. That is a real answer and it is better delivered early.
