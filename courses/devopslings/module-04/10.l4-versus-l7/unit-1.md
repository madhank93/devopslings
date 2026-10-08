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

Cases 1 and 4 are both HTTPS and land on opposite layers. Working out why is
most of the exercise.

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
| Connections | one, forwarded (an L4 *proxy* opens two, but only copies bytes) | two, one either side |
| Can route on | address, port (and SNI, without decrypting) | header, path, method, cookie |
| Can terminate TLS | yes — decrypts and forwards the bytes without reading the HTTP inside (AWS NLB TLS listener, HAProxy `mode tcp`) | yes, and then reads the request |
| Backend sees source | the real client, when the balancer passes packets through (NAT, DSR); an L4 proxy hides it too | the balancer |
| Understands your protocol | does not need to | must |
| Cost per connection | low | parse, buffer, re-encrypt |

The TLS row is the one people get wrong. Where TLS ends and whether anything
reads what is inside are separate choices. Only the second one is L7.

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

In two of these cases one of those costs is disqualifying. For TLS, "end-to-end
semantics" includes who holds the key and who sees the client's certificate.

</details>

<details>
<summary>Hint 3 — cases 1 and 4 are both HTTPS</summary>

Terminating TLS is not what makes a balancer L7; reading the request after
decryption is. So for case 1, ask which requirement needs the request read.
For case 4, ask whether anything but the backend may decrypt at all.

</details>

## Working through them

**Case 1 — the checkout front end.** TLS must end before the application, and
that looks like the deciding constraint. It is not: an L4 balancer with a TLS
listener terminates TLS and forwards the decrypted bytes without reading them,
and the application team still never holds the key.

What an L4 balancer cannot do is send `/api/` to one pool and everything else to
another. The path is inside each HTTP request, and a single keep-alive
connection carries requests for both pools. Choosing per request means parsing
every request, and that is L7. The `X-Request-Id` rewrite needs the same.

`layer=l7 because=routing`. `termination` is the distractor: it is required, and
both layers can do it.

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
balancer's address — always, by construction. (So does an L4 *proxy*; this
needs an L4 balancer that passes packets through, which is the usual kind.)

The usual answer is `X-Forwarded-For`. The auditors explicitly rejected it, and
their reasoning is sound: a header is a claim made by whoever wrote it, and
trusting it means trusting every hop that could have set it. The connection's
source address is not a claim.

`layer=l4 because=sourceaddress`.

**Case 4 — the settlement API.** HTTPS again, and the opposite answer.

Before an L7 balancer can read a byte of HTTP it has to decrypt, and to decrypt
it has to hold the service's private key. The policy forbids exactly that. It
would also break authentication: the TLS handshake the backend sees would be the
balancer's, so the backend would verify the balancer's certificate, not the
caller's — and the balancer presenting one on the caller's behalf is the other
thing the policy forbids.

An L4 balancer forwards the connection with the handshake untouched. The backend
holds the only key and sees the caller's certificate itself. No routing is
needed, so nothing is lost.

`layer=l4 because=termination`. Same token that case 1 is tempted by, opposite
direction: case 1 needs TLS to end at the balancer and both layers can do it;
case 4 needs TLS *not* to end there, and only L4 leaves it alone.

## Solving it

<details>
<summary>Solution</summary>

```
case-1: layer=l7 because=routing
case-2: layer=l4 because=protocol
case-3: layer=l4 because=sourceaddress
case-4: layer=l4 because=termination
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
2. **Does anything require the request to be read at the balancer?** Path or
   header routing, header rewriting, response caching. If yes, L7 — and accept
   the costs. Key custody alone is not this: an L4 TLS listener covers it.
3. **Does anything require the connection to survive intact?** Source address,
   end-to-end TLS, a protocol nobody else parses. If yes, L4.

When 2 and 3 are both yes, no load balancer resolves it and the design has to
change. That is a real answer and it is better delivered early.
