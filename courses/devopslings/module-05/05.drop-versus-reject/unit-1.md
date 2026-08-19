---
title: "one dependency hangs, the other is refused, and both are the same firewall"
---

## The situation

The orders service calls two dependencies. Both calls started failing at the
same moment, and they fail in completely different ways:

```
$ time curl http://10.80.0.5:9001/      # inventory
curl: (28) Connection timed out after 6001 milliseconds
real    0m6.035s

$ time curl http://10.80.0.6:9002/      # shipping
curl: (7) Failed to connect to 10.80.0.6 port 9002: Connection refused
real    0m0.015s
```

Six seconds against fifteen milliseconds. Four hundred times apart, from the
same box, to two hosts on the same network, in the same second.

Both dependency hosts are up. Both services are running and correct — you can
prove it from inside their own network, where they answer instantly.

So there are two tickets, and they will be routed to two different teams, and
both of them are the same firewall on this box.

## The two signatures

A packet arriving at a rule has three possible fates, and two of them are
failures that look nothing alike from the client:

| Verdict | What goes back | What the client sees |
|---|---|---|
| `accept` | the packet proceeds | it works |
| `drop` | **nothing at all** | silence, until the client's own timeout fires |
| `reject` | an RST or an ICMP error | an immediate, explicit refusal |

That is the whole mechanism. `drop` is silence; `reject` is an answer.

The consequence is that **the time-to-failure tells you which verdict you are
looking at, before you read a single rule**:

- **Slow failure, ending on a round number** — 5s, 30s, 6001ms. That number is
  your own timeout, not anything the network chose. Nobody replied. Something
  dropped it.
- **Instant failure** — faster than a round trip could possibly be. Somebody
  replied, and the reply was a refusal.

Learn to read the clock and you have halved the problem before you start.

## Your objective

Make both dependencies return their pages.

`10.80.0.9` is a decommissioned host, quarantined on purpose. **It must still be
unreachable from this box when you are finished** — so `nft flush ruleset` is not
a fix, even though it makes both symptoms disappear.

Then write `/root/answers/blocked.md`, exactly two lines:

```
inventory: signature=<timeout|refused> rule=<drop|reject>
shipping: signature=<timeout|refused> rule=<drop|reject>
```

## What you're being graded on

Both dependencies serving their pages, `10.80.0.9` still blocked, and both lines
of the answer file matching the rule that actually produced each symptom.

<details>
<summary>Hint 1 — time the two calls</summary>

```
$ time curl -m 10 http://10.80.0.5:9001/
$ time curl -m 10 http://10.80.0.6:9002/
```

Do not skip this because you already know both are "blocked". The difference in
elapsed time is the evidence, and it is the only evidence you need to tell the
two rules apart.

Also check `curl`'s exit code: `28` is a timeout, `7` is a refusal.

</details>

<details>
<summary>Hint 2 — read the ruleset with handles</summary>

```
$ nft -a list ruleset
```

`-a` prints a `# handle N` comment on every rule. That number is how you delete
one rule without touching its neighbours:

```
$ nft delete rule inet appfw output handle 4
```

Read all three rules before deleting anything. One of them is there on purpose.

</details>

<details>
<summary>Hint 3 — prove the services are innocent</summary>

```
$ ip netns exec deps curl http://10.80.0.5:9001/
inventory-canonical-2026
```

From inside the dependency network, all three answer immediately. The rules are
on this box, in the `output` chain — the packets are being stopped on the way
out, before they ever reach a dependency.

That is worth noticing on its own: a firewall on the *client* produces failures
that look exactly like a broken server.

</details>

## Why the difference exists

Both verdicts block traffic. They differ in what they tell the sender, and the
choice between them is a real trade-off:

- **`drop`** gives an attacker nothing. A port scan cannot distinguish a dropped
  port from a host that does not exist, so a scan of a dropped range is slow and
  uninformative. This is why internet-facing rules default to `drop`.
- **`reject`** fails fast. A client learns immediately that the door is closed
  and can fall back, retry elsewhere, or return an error to its own caller in
  milliseconds instead of holding a connection open for thirty seconds.

Inside a datacentre, `drop` on internal traffic is usually the wrong default and
gets chosen anyway, by habit copied from perimeter rules. The cost is not
theoretical: every dropped call holds a connection, a thread, and a slot in some
pool for the full timeout. A dependency that refuses instantly degrades a
service. A dependency that drops silently exhausts it.

If you write firewall rules for internal traffic, `reject` is usually kinder,
and the kindness is measured in your own service's thread pool.

## What actually happened

Three rules, added at different times for different reasons, all in the `output`
chain of one table:

```
ip daddr 10.80.0.5 tcp dport 9001 drop                    # inventory
ip daddr 10.80.0.6 tcp dport 9002 reject with tcp reset   # shipping
ip daddr 10.80.0.9 drop                                   # quarantined host
```

The first two were someone's change, applied to the wrong addresses. The third
is deliberate and has to stay — which is exactly why the instinctive fix,
flushing the ruleset, is wrong. It resolves the incident and silently
un-quarantines a decommissioned host, and nobody will notice until that host
starts receiving traffic again.

<details>
<summary>Solution</summary>

```
$ nft -a list chain inet appfw output
  ip daddr 10.80.0.5 tcp dport 9001 drop # handle 4
  ip daddr 10.80.0.6 tcp dport 9002 reject with tcp reset # handle 5
  ip daddr 10.80.0.9 drop # handle 6

$ nft delete rule inet appfw output handle 4
$ nft delete rule inet appfw output handle 5
```

```
inventory: signature=timeout rule=drop
shipping: signature=refused rule=reject
```

Delete by handle, one rule at a time. `nft flush ruleset`, `nft delete table`,
and `nft flush chain` all make both symptoms go away and all take the quarantine
with them.

</details>

## Carrying this forward

Two habits from this one:

- **Time your failures.** "It doesn't work" is not a diagnosis; "it fails in 15
  milliseconds" nearly is. A round-numbered delay is your own timeout and means
  nobody answered. An instant failure means somebody did.
- **Never flush a ruleset to fix a rule.** The rules you did not write are the
  ones with reasons you do not know. Delete by handle.

`curl` exit codes are worth memorising for this module: `6` could not resolve
host, `7` could not connect, `28` timed out. Three of the failures in this
module are already distinguishable by that number alone.

The next lesson keeps everything correct — the name, the route, the firewall,
the service — and breaks only the size of the packets. Small requests will work
perfectly, and large ones will hang forever.
