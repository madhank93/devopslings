---
title: "dig resolves it, the application cannot, and both are telling the truth"
---

## The situation

The billing service cannot reach `payments.internal`. Its log says, over and
over:

```
Could not resolve host: payments.internal
```

You check the name yourself, on the same box, one second later:

```
$ dig payments.internal +short
10.70.0.6
```

Correct. Every time. The record exists, the resolver is up, the network is fine,
and the machine that cannot resolve the name is the machine you just resolved it
on.

This is the point where people start reaching for explanations that are not
true: a caching bug in the application, a stale container image, "it must be
DNS propagation". None of those. Both observations are accurate, and they are
accurate about **different components**.

## dig is not a resolver client in the way you think

`dig` is a DNS tool, and only a DNS tool. It reads `/etc/resolv.conf` for a
server address, builds a DNS query, sends it, and prints the reply.

Your application does not do any of that. It calls `getaddrinfo()`, which is
part of the C library, and `getaddrinfo()` does **not** start with DNS. It
starts with `/etc/nsswitch.conf`:

```
hosts:          files dns myhostname
```

That line is a list of *sources*, consulted left to right:

- `files` — `/etc/hosts`
- `dns` — the resolver, i.e. the only thing `dig` has ever talked to
- `myhostname` — the machine's own name and addresses

`dig` bypasses this list completely. It is not a client of the same machinery.
So a box can be in a state where DNS is flawless and no application on it can
resolve a single name, and `dig` will report success the whole time — because
`dig` is the one tool on the box that never asks the question the applications
are asking.

## Your objective

Make `curl http://payments.internal:8080/` return the page containing
`payments-canonical-2026`.

Then write `/root/answers/resolution.md`, one line:

```
file=<absolute path of the file that was wrong> missing=<the one word missing from it>
```

Constraints:

- **Nothing added to `/etc/hosts`.**
- **No changes to `/etc/dnsmasq.d/lab.conf`.**
- **`getent hosts localhost` must still work when you are done.**

## What you're being graded on

`getent hosts payments.internal` returning `10.70.0.6`, the page served,
`localhost` still resolving, `/etc/hosts` untouched, and the answer file naming
the file and the missing source.

<details>
<summary>Hint 1 — get a second opinion that is not dig</summary>

```
$ dig payments.internal +short
$ getent hosts payments.internal
```

`getent hosts` goes through `getaddrinfo()` — the same path the application
takes. When those two disagree, the disagreement is the entire diagnosis: the
problem is between `getaddrinfo` and DNS, not inside DNS.

Any time you are tempted to conclude "DNS is broken", run both.

</details>

<details>
<summary>Hint 2 — read the line, count the words</summary>

```
$ grep '^hosts:' /etc/nsswitch.conf
```

Compare what is on that line against the three sources described above. One of
them is missing, and it is the one that would have made the resolver reachable.

</details>

<details>
<summary>Hint 3 — do not just delete the problem</summary>

Whatever you put on that line, `files` has to stay on it. `/etc/hosts` is how
`localhost` resolves, and a box where `localhost` does not resolve is broken in
a way that is much worse and much harder to notice than the fault you started
with.

</details>

## What was actually wrong

```
hosts:          files myhostname
```

No `dns`. The resolver was never in the lookup path. Every application on the
box had been resolving names out of `/etc/hosts` alone and failing on everything
not listed there, while `dig` — which never consults this file — reported
perfect health.

The fix is one word:

```
hosts:          files dns myhostname
```

Order matters and the conventional order is deliberate. `files` first means
`/etc/hosts` can override DNS, which is what makes a hosts-file entry a working
emergency measure. Putting `dns` first would mean the resolver wins over local
overrides — occasionally what you want, usually a surprise.

## Why `/etc/hosts` is the wrong fix

Adding `10.70.0.6 payments.internal` to `/etc/hosts` makes the symptom
disappear in about four seconds, and it is why this failure survives so long in
real infrastructure.

It fixes exactly one name. Every other name on the box is still unresolvable,
and nobody finds out until the next service is added — at which point the same
four-second fix is applied again, and the box accumulates a hosts file that is a
private, unversioned, silently-diverging copy of DNS. Then a record changes, and
that machine keeps using the old address forever.

The symptom was one name. The fault was that the box had no DNS at all.

<details>
<summary>Solution</summary>

```
$ sed -i 's/^hosts:.*$/hosts:          files dns myhostname/' /etc/nsswitch.conf
$ getent hosts payments.internal
10.70.0.6       payments.internal
$ curl http://payments.internal:8080/
payments-canonical-2026
```

```
file=/etc/nsswitch.conf missing=dns
```

No daemon restart is needed. `getaddrinfo()` reads `nsswitch.conf` per lookup,
so the change takes effect on the next call — though a long-running process that
cached a previous failure may need a nudge.

</details>

## Carrying this forward

`dig` answers questions about DNS. `getent hosts` answers questions about *what
your application will get*. They are different questions and only one of them is
the one you actually have.

Make the pair a habit: when a name resolves for you and not for the service,
that is not a contradiction to explain away. It is a measurement, and it points
at `nsswitch.conf`, at a container with a different `/etc` than the host, or at
a static binary that never linked the NSS modules at all — a Go binary built
with `CGO_ENABLED=0` uses its own resolver and ignores this file entirely, which
is the same class of surprise wearing different clothes.

The last two lessons were both name resolution. The next moves down a layer: the
name resolves, the connection is attempted, and the service refuses it — because
it is listening, but not where you think.
