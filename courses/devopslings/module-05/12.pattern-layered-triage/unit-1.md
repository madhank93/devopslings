---
title: "one symptom, and the cause is somewhere in the stack"
---

## The situation

```
$ curl -sS -m 8 https://api.partner.internal:8443/health
```

It should print `payments-api ok`. It does not. That is the entire ticket, and
it will be the entire ticket every time you run this lesson — because the fault
is drawn at random from five and seeded somewhere between the frame leaving
this box and the certificate the API presents.

You cannot memorise the answer. You can only memorise the ladder.

## Why the ladder exists

A failing request has one symptom and six or seven possible homes, and the
homes are ordered. Layer 2 breaks the frame, so nothing above it can work. Layer
3 breaks the next hop, so nothing above it can work. Each layer is built on the
one below and reports nothing about it: `curl` says "connection timed out"
whether the cause is a wrong MAC address, a missing route, a firewall three hops
away, or a name pointing at an address nobody owns.

This is why "start at the application, because that is where the error message
is" fails so reliably. The error message is written by the top of the stack
about a failure that happened underneath it. It is the last place with
information, not the first.

Working bottom-up costs six commands and answers the question. Working top-down
costs an afternoon, because every layer you inspect looks broken — they are all
broken, downstream of the one that actually is.

## The ladder, one rung at a time

Each rung has a tool, and each tool tells you one thing. The first rung that
fails is the fault. Everything above it is a consequence and everything below
it is already proven.

**Layer 2 — is there a station to send the frame to?**

```
$ ip neigh show 10.94.0.2 dev to-gw
10.94.0.2 dev to-gw lladdr 02:00:5e:00:53:99 PERMANENT
```

An IP packet cannot leave a link until it is wrapped in a frame addressed to a
MAC. That mapping is the neighbour table. `PERMANENT` is the tell: a learned
entry says `REACHABLE` or `STALE` and expires; a permanent one was typed in by
a human and will never be corrected by the network no matter how wrong it is.
Compare it against the address the router actually has:

```
$ ip netns exec gw cat /sys/class/net/gw-box/address
```

If they differ, every packet is being handed to a station that does not exist.
Nothing above layer 2 will ever be told.

**Layer 3 — does the packet have a next hop?**

```
$ ip route get 10.94.1.9
10.94.1.9 via 172.31.0.1 dev eth0 src 172.31.0.10
```

`ip route get` asks the kernel to make the same decision it would make for a
real packet, which is worth far more than reading the table and doing the
longest-prefix match in your head. A missing specific route does not produce an
error — it produces a *different* answer, as here, where the default route has
quietly volunteered to carry traffic for a subnet it knows nothing about.

**Layer 4 — is the port open along the whole path?**

```
$ ping -c2 10.94.1.9        # replies
$ nc -vz 10.94.1.9 8443     # hangs, then times out
```

Those two results together are a very specific signature: the addresses are
right, the path is up, and something is filtering by port. It is not the
endpoint's firewall — check the machine in the middle, which is the one with an
opinion about traffic that is neither from it nor to it:

```
$ ip netns exec gw nft list ruleset
```

A `drop` in the `forward` chain is invisible from both ends. Neither endpoint
logs it, because neither endpoint is where it happened.

**Layer 7 — does the name answer, and is the answer right?**

```
$ dig +short api.partner.internal @127.0.0.1
10.94.1.99
```

Resolution succeeding is not resolution being correct. A name that answers
promptly with the wrong address produces a perfectly healthy connection attempt
to a host that does not exist, and every layer below is functioning exactly as
designed. The check is not "does it resolve" but "does it resolve to the thing
that is actually listening".

**Layer 6 — is the certificate for the name you asked for?**

```
$ openssl s_client -connect 10.94.1.9:8443 -servername api.partner.internal
...
subject=CN=api-internal.partner.example
Verify return code: 21 (unable to verify the first certificate)
```

By this rung the TCP connection is established — that is what makes it distinct
from everything below. The handshake is a separate negotiation on top of a
working connection, and it can fail for two unrelated reasons: the chain does
not verify (a trust problem) or the name on it is not the name you asked for (a
naming problem). `-servername` sends SNI, so the server picks a certificate the
same way a real client would make it.

## Your objective

Two things.

1. Make the health check pass, by repairing what was broken. Not by routing
   around it: the name must still resolve through the resolver on 127.0.0.1,
   the traffic must still go via 10.94.0.2, the API must stay where it is, and
   the certificate must still verify against the partner internal CA for the
   name being asked for.

2. Write `/root/answers/triage.md`, exactly two lines:

   ```
   layer: <number>
   cause: <arp | route | firewall | dns | tls>
   ```

The router and the API are network namespaces on this box. `ip netns exec gw`
and `ip netns exec api` reach them, and everything in either is readable.

## What you're being graded on

**The health check passes.** `payments-api ok`, over TLS, with verification on.

**You did not make the symptom go away without fixing anything.** Four
sidesteps are checked for by name, because all four work and all four leave the
fault in place:

- an `/etc/hosts` entry for `api.partner.internal` — bypasses the resolver
  rather than repairing it, and helps exactly one machine
- `insecure` in `/root/.curlrc` — makes the client stop checking the thing that
  was wrong
- a new CA, or a certificate for a different name — the chain is verified
  against the CA the scenario built, for the name the client asks for
- a route that does not go via 10.94.0.2 — the path through the router is the
  scenario

**You can name the layer.** The number, and the one-word cause. This is the
half that makes the next incident faster: a fault you repaired but cannot place
is a fault you will re-diagnose from scratch when it recurs somewhere else.

For TLS, both 6 and 7 are accepted — the handshake is presentation and the name
checked inside it is what the application asked for, and that argument has no
correct side. Everywhere else the layer is not arguable.

<details>
<summary>Hint 1 — the whole ladder, six commands</summary>

```
$ ip neigh show 10.94.0.2 dev to-gw
$ ip netns exec gw cat /sys/class/net/gw-box/address
$ ip route get 10.94.1.9
$ ping -c2 10.94.1.9
$ nc -vz 10.94.1.9 8443
$ dig +short api.partner.internal @127.0.0.1
$ echo | openssl s_client -connect 10.94.1.9:8443 -servername api.partner.internal
```

Run them in that order and stop at the first one whose answer is wrong. Do not
run them in a different order to save time — the saving is imaginary, because
an answer from a higher rung cannot be interpreted until the lower ones are
known good.

</details>

<details>
<summary>Hint 2 — three faults look identical from curl</summary>

A wrong neighbour entry, a missing route and a `drop` on the router all produce
the same thing: a connection that never completes. Separating them takes two
observations.

Does anything come back at all? `ping 10.94.1.9`. A reply means layers 2 and 3
are fine end to end, which leaves the port.

Where would the packet go? `ip route get 10.94.1.9`. If the next hop is not
10.94.0.2, nothing else you check matters yet.

And the two that are *not* timeouts are the informative ones: DNS answering the
wrong address gives a fast connection attempt to nothing, and a certificate for
another name gives an error after the TCP connection is already up.

</details>

<details>
<summary>Hint 3 — repairing rather than routing around</summary>

Each fault has a repair at the layer it lives on:

- a static neighbour entry that is wrong should be removed, not corrected —
  the address is meant to be learned
- a missing route goes back with `ip route replace 10.94.1.0/24 via 10.94.0.2
  dev to-gw`
- the router's ruleset is `ip netns exec gw nft list ruleset`, and a table it
  added can be deleted
- the zone is `/etc/dnsmasq.d/partner.conf`, and dnsmasq needs a restart
- which keypair the API presents is `/etc/api/tls.conf`, and both certificates
  are already on the box

An `/etc/hosts` entry, `curl -k`, a new CA and a route around the gateway all
make the symptom stop. All four are checked for and rejected.

</details>

## What actually happened

One of five, and which one is in the digest at `/var/lib/drill/state` rather
than in a word — not because it is a secret, but because reading it teaches
nothing and the drill only pays if you walk the ladder.

| Cause | Layer | What was done | The tell |
|---|---|---|---|
| `arp` | 2 | a permanent neighbour entry for the router with a MAC nothing answers to | `ip neigh` shows `PERMANENT`, and the MAC does not match the router's |
| `route` | 3 | the specific route to 10.94.1.0/24 deleted | `ip route get` returns the default route's next hop |
| `firewall` | 4 | a `drop` for tcp/8443 in the router's forward chain | ping crosses, the port does not |
| `dns` | 7 | the zone answers with 10.94.1.99 | resolution succeeds; the address is not the API's |
| `tls` | 6 | the API serves the certificate for `api-internal.partner.example` | the connection establishes and the handshake does not |

Note what every one of these has in common: the layer where the fault lives is
silent about it, and the layer at the top produces the error message. In four
of the five, nothing is logged anywhere. The `drop` is not logged. The wrong
neighbour entry is not logged. DNS answering the wrong address is, from DNS's
point of view, a success.

Diagnosis by log-reading has nothing to read. Diagnosis by ladder has one
command per rung.

<details>
<summary>Solution</summary>

There is no fixed answer, so the solution is the ladder as a script — which is
exactly what the reference solution does. Each rung is checked only if every
rung below it passed:

```bash
# layer 2 — is the neighbour entry a MAC the router actually has?
real=$(ip netns exec gw cat /sys/class/net/gw-box/address)
have=$(ip -o neigh show 10.94.0.2 dev to-gw | sed -n 's/.*lladdr \([0-9a-f:]*\).*/\1/p')
[ -n "$have" ] && [ "$have" != "$real" ] && ip neigh del 10.94.0.2 dev to-gw

# layer 3 — does the packet still leave via the router?
ip route get 10.94.1.9 | head -1 | grep -q 'via 10.94.0.2' \
  || ip route replace 10.94.1.0/24 via 10.94.0.2 dev to-gw

# layer 4 — does the port open?
timeout 5 bash -c 'exec 3<>/dev/tcp/10.94.1.9/8443' \
  || ip netns exec gw nft delete table inet drill

# layer 7 — does the name answer with the address that is listening?
[ "$(dig +short api.partner.internal @127.0.0.1 | tail -1)" = 10.94.1.9 ] \
  || { sed -i 's#^address=/api.partner.internal/.*#address=/api.partner.internal/10.94.1.9#' \
         /etc/dnsmasq.d/partner.conf; systemctl restart dnsmasq; }

# layer 6 — is the certificate for the name being asked for?
sed -i -e 's#^cert=.*#cert=/etc/pki/api/api.crt#' \
       -e 's#^key=.*#key=/etc/pki/api/api.key#' /etc/api/tls.conf
systemctl restart payments-api
```

Then record which rung answered:

```
$ printf 'layer: 4\ncause: firewall\n' > /root/answers/triage.md
```

Writing the ladder down as a script is worth doing once even though you will
run it by hand. It forces the order to be explicit, and the order is the part
that transfers.

</details>

## Carrying this forward

The specific five do not matter — they are stand-ins. What transfers is the
shape:

- **Ask each layer with a tool that only knows about that layer.** `ip neigh`
  cannot tell you about routes; that is the point. A tool that spans layers,
  like `curl`, gives you one verdict for six possible causes.
- **The first rung that fails is the fault.** Do not fix the second thing you
  find broken. Above the fault, everything is broken.
- **"It resolves" and "it responds" are not the same claim.** Nor are "the
  connection opened" and "the handshake completed". Most wasted triage time is
  spent treating one as evidence for the other.
- **The machine in the middle has opinions nobody logs.** When both endpoints
  look healthy, the thing between them is where to look, and it is usually the
  one box you did not think you owned.

Run the lesson again. The fault moves, and the ladder does not.
