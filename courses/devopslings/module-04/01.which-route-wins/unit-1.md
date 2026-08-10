---
title: "three routes match, and the one you read first is not the one that wins"
---

## The situation

The partner network is `10.50.0.0/16`, reached through this box. Half of it
answers and half of it does not:

```
$ curl http://10.50.1.5:8080/
partner-net-2026

$ curl http://10.50.7.5:8080/
curl: (28) Connection timed out after 5001 milliseconds
```

Both addresses are the same host on the far side. The same web server serves
both. Nothing on the far side distinguishes them.

The first thing anyone does is check the route, and the route is fine:

```
$ ip route show | grep 10.50
10.50.0.0/16 via 10.60.0.2 dev to-partner
```

There it is. Correct nexthop, correct interface, up. At this point the
conversation usually moves on to the far side, or to a firewall, because "the
routing is fine — look".

It is not fine. The command that was run does not answer the question that was
asked.

## Your objective

Make `10.50.7.5` reachable, without

- removing the `10.50.0.0/16` route,
- removing the default route,
- or breaking `10.50.1.5`, which already works.

The far side serves a page containing `partner-net-2026`.

## What you're being graded on

The default route and the `/16` still present, `ip route get 10.50.7.5` no
longer resolving through the dead gateway, and both `10.50.7.5` and `10.50.1.5`
serving the page.

<details>
<summary>Hint 1 — grep is the problem</summary>

`ip route show | grep 10.50` returns the lines that contain the text `10.50`.
That is a question about strings. The kernel is not matching strings.

Look at the whole table, unfiltered. Count how many entries could carry a packet
addressed to `10.50.7.5`.

</details>

<details>
<summary>Hint 2 — there are three</summary>

```
default via 172.31.0.1 dev eth0
10.50.0.0/16 via 10.60.0.2 dev to-partner
10.50.7.0/24 via 172.31.0.99 dev eth0
```

All three match `10.50.7.5`. The default route matches every address. The `/16`
matches the whole partner network. The `/24` matches the address in question.

Only one of them is used.

</details>

<details>
<summary>Hint 3 — stop guessing and ask</summary>

```
$ ip route get 10.50.7.5
```

`ip route show` lists what is configured. `ip route get` performs the actual
lookup — the same one the kernel does for a real packet — and prints the answer.

Run it for `10.50.1.5` too, and compare.

</details>

## The rule

The kernel selects the route with the **longest matching prefix**. Most specific
wins.

`/24` is more specific than `/16`, which is more specific than `/0`. For any
address inside `10.50.7.0/24`, the `/24` entry is chosen and the other two are
never considered. For `10.50.1.5`, the `/24` does not match at all, so the `/16`
wins — which is exactly why one address worked and the other did not.

Three things people expect to matter, which do not:

- **Order in the output.** `ip route show` sorts for display. The kernel's
  lookup structure is not a list being walked top to bottom.
- **Metric.** Metric breaks ties *between routes of the same prefix length*. It
  never lets a `/16` beat a `/24`. Lowering the metric on the `/16` here would
  change nothing at all.
- **Which interface is "the real one".** The kernel picks the route first, and
  the route names the interface. Not the other way round.

## What actually happened

`172.31.0.99` was the partner gateway. It was decommissioned. The `/16` was
added pointing at the new path, the box was tested against `10.50.1.5`, it
worked, and the change was closed.

The `/24` was never removed. It kept winning for one twenty-fifth of the partner
network, and pointed at an address that no longer answers ARP — so packets to
those addresses were handed to a nexthop that does not exist and went nowhere.
No error, no log line, no `EHOSTUNREACH`. The kernel had a route. It used it.

This is the ordinary shape of the failure: a correct route added alongside a
stale one, and the stale one is more specific.

<details>
<summary>Solution</summary>

```
$ ip route del 10.50.7.0/24 via 172.31.0.99 dev eth0
```

With the `/24` gone, `10.50.7.5` falls through to the `/16` like the rest of the
partner network.

Repointing it instead would also work:

```
$ ip route replace 10.50.7.0/24 via 10.60.0.2 dev to-partner
```

…and it is the worse answer. It leaves a redundant, more-specific route in the
table whose only job is to duplicate the `/16`. The next time the partner path
moves, the `/16` will be updated and this entry will be forgotten again, and the
same twenty-fifth of the network will break the same way.

Delete routes that have stopped meaning something. A route that agrees with its
parent is a future incident with a delay fuse.

</details>

## Carrying this forward

When something is reachable at one address and not another, and both are on the
same far-side host, the difference is on your side and it is almost always route
selection.

`ip route get <addr>` is the first command, not the third. It answers which
route wins, which source address will be used, and which interface the packet
leaves by — three things `ip route show` only lets you infer.

The same rule appears again in the next lesson with two default routes, where
both entries have the same prefix length and the tie really is broken by metric.
