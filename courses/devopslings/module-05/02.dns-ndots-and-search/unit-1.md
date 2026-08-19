---
title: "the resolver answers instantly, and it answers the wrong host"
---

## The situation

The application talks to `api.internal`. It has started reaching a machine
nobody deployed to — `10.70.0.99`, which belongs to another team and answers
with their content.

The DNS server is the first suspect and it is immediately cleared:

```
$ dig api.internal @127.0.0.1 +short
10.70.0.6
```

Correct, every time you run it. The record is right, the server is healthy, the
network is fine. And the application still gets `10.70.0.99`.

At this point the usual move is to blame the application's DNS cache, or its
HTTP client, or to add an `/etc/hosts` entry and move on. All three are wrong,
and the third one is wrong in the way that follows you to production.

## Your objective

Make `curl http://api.internal:8080/` reach `10.70.0.6` and return the page
containing `api-canonical-2026`.

Constraints, all of which exist for a reason:

- **Keep the `search` line** in `/etc/resolv.conf`. Every short name on this box
  depends on it.
- **Do not touch `/etc/dnsmasq.d/lab.conf`.** The `corp.internal` wildcard is
  another team's record. In a real network you cannot delete it.
- **Do not add anything to `/etc/hosts`.**

## What you're being graded on

`api.internal` resolving to `10.70.0.6` through the normal path, the page coming
back, the `search` line and the wildcard both still in place — and the resolver
no longer being asked for suffixed names it should never have been asked for.

That last one is the real bar. There is more than one way to get the right
address here, and only one of them stops the wasted queries.

<details>
<summary>Hint 1 — dig is not what your application uses</summary>

`dig` is a DNS tool. It sends the query you typed, to the server you named, and
prints what comes back.

Your application does not do that. It calls `getaddrinfo()`, which reads
`/etc/resolv.conf` and applies rules `dig` ignores entirely.

Compare:

```
$ dig api.internal +short
$ getent hosts api.internal
```

`getent hosts` goes through the same resolver path the application does. Look at
the **name** in its output, not just the address.

</details>

<details>
<summary>Hint 2 — read the whole resolv.conf</summary>

```
nameserver 127.0.0.1
search corp.internal svc.internal internal
options ndots:5
```

Three lines, and everyone reads the first one.

`search` is a list of suffixes to append. `ndots` decides *when* they get
appended — and it is the line that is actually doing this.

</details>

<details>
<summary>Hint 3 — watch the queries</summary>

The resolver logs every question it is asked:

```
$ journalctl -u dnsmasq -f
```

Leave that running and, in another shell, `getent hosts api.internal`. Read the
order of the queries. The first one is not the one you typed.

</details>

## The rule

`ndots:N` means: **if the name has fewer than N dots, try it with each search
suffix appended _before_ trying it as written.**

`api.internal` has one dot. With `ndots:5`, one is fewer than five, so the
resolver works through this list in order:

```
api.internal.corp.internal   ← asked first
api.internal.svc.internal
api.internal.internal
api.internal                 ← asked last, if it gets that far
```

It never gets that far. `corp.internal` has a wildcard record, so
`api.internal.corp.internal` resolves — to `10.70.0.99`. The search stops at the
first name that answers. The correct record for `api.internal` is never
consulted.

This is why `dig` looked fine. `dig api.internal` sends exactly that name, with
no suffix and no search list. It was answering a question the application never
asked.

Two things worth carrying:

- **A wildcard turns a search list into a trap.** Without the wildcard, the
  first three lookups would NXDOMAIN and the fourth would find the right record
  — slow, but correct. One wildcard anywhere in your search path converts
  "slightly wasteful" into "silently wrong".
- **`ndots:5` is not a strange number.** It is Kubernetes' default, in every
  pod, which is why this failure is so common there and why the folklore fix
  ("put a dot on the end") gets passed around without the mechanism.

## What actually happened

`ndots:5` was copied off a Kubernetes cluster, where it exists so that
`service`, `service.namespace` and `service.namespace.svc` all resolve as short
names. On a plain box with a `search` list that contains somebody else's
wildcard domain, it means every internal name is offered to that wildcard first.

It worked for months, because `corp.internal` had no wildcard for months. The
record was added by another team, for their own reasons, and broke a machine
they have never heard of.

<details>
<summary>Solution</summary>

```
$ sed 's/^options ndots:5$/options ndots:1/' /etc/resolv.conf > /tmp/r
$ cat /tmp/r > /etc/resolv.conf
```

`/etc/resolv.conf` is a bind mount in a container, so it is written **in place**.
`sed -i` renames a temp file over the target and the rename fails on a mount
point — a detail worth remembering, because it fails the same way for every
config file Docker injects.

With `ndots:1`, a name containing at least one dot is tried as written first.
`api.internal` is asked for directly, the correct record answers, and no suffix
is ever appended.

**Two fixes that look right and are not:**

Reordering the search list so `corp.internal` comes last gets you `10.70.0.6` —
and the box still asks for `api.internal.svc.internal` first. You have moved the
trap, not removed it. The next wildcard, in whichever domain now comes first,
reopens it.

Querying `api.internal.` with a trailing dot is correct and is the fix for *one
call site*. The trailing dot makes the name absolute, so no search list applies.
It works, and it has to be done everywhere the name appears — every config file,
every environment variable, every hardcoded string. `ndots` fixes the box once.

</details>

## Carrying this forward

When a name resolves correctly under `dig` and incorrectly in the application,
stop testing with `dig`. `getent hosts` is the one that shares the
application's path.

And when you see `ndots:5` in a `resolv.conf` that is not inside a Kubernetes
pod, treat it as a bug until proven otherwise. It was almost certainly copied.

The next lesson takes the other half of this: `dig` and the application
disagreeing even when the search list is not involved at all — because
`getaddrinfo` consults `nsswitch.conf` first, and DNS may not be the first thing
it reaches for.
