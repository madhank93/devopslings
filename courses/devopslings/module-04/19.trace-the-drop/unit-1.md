---
title: "the allow rule is right there, and the database is still unreachable"
---

## The situation

`fw2` is the firewall between the app tier and the database tier. Redis works
and Postgres doesn't:

```
$ ip netns exec apps nc -w3 10.92.2.10 6379
db-redis-ok
$ ip netns exec apps nc -w3 10.92.2.10 5432
$
```

The ruleset has a rule that accepts both:

```
chain apps_to_db {
    ip daddr 10.92.2.10 tcp dport @db_ports counter accept
    ...
}
set db_ports {
    type inet_service
    elements = { 5432, 6379 }
}
```

The full ruleset is seven chains, three sets and about twenty-five rules. You
could read it top to bottom, following every jump by hand. Or you could ask the
kernel.

## Your objective

1. Find the rule that drops the Postgres connection and write
   `/root/answers/trace.md` with its chain and handle.
2. Make Postgres reachable from the app tier and keep it that way after a
   reboot. The dev server on `db:5001` stays blocked, because SEC-118 still
   stands.

## What you're being graded on

The answer names the dropping rule's chain and handle. Postgres and Redis are
reachable and `:5001` isn't. `/etc/fw2/ruleset.nft` loads exactly the ruleset
that's running, with no trace rule left over.

<details>
<summary>Hint 1: mark one packet</summary>

nftables can trace a packet through every chain and rule it visits. First you
mark the packets you care about by setting `nftrace` on them, in a chain that
runs before everything else:

```
$ ip netns exec fw2 nft add chain inet fw2 trace_pre '{ type filter hook prerouting priority -350; }'
$ ip netns exec fw2 nft add rule inet fw2 trace_pre ip saddr 10.92.1.30 tcp dport 5432 meta nftrace set 1
```

Then watch, and send one packet from another terminal:

```
$ ip netns exec fw2 nft -a monitor trace
$ ip netns exec apps nc -w2 10.92.2.10 5432
```

</details>

<details>
<summary>Hint 2: read the trace</summary>

```
trace id a10793eb inet fw2 forward rule iifname "apps0" jump from_apps (verdict jump from_apps)
trace id a10793eb inet fw2 from_apps rule oifname "db0" jump baseline_cross_zone (verdict jump baseline_cross_zone)
trace id a10793eb inet fw2 baseline_cross_zone rule tcp dport 5000-5999 counter packets 0 bytes 0 drop # handle 26 (verdict drop)
```

That's every rule the packet matched, in order, ending with the one that gave
the verdict. With `-a` you also get the rule's handle.

</details>

## Why reading did not find it

The rule that should accept Postgres sits in `apps_to_db`. Every apps-to-db flow
reaches that chain only *after* `from_apps` has jumped through
`baseline_cross_zone`, a shared chain of things no cross-zone flow should ever
do. One of those things is SEC-118's "developer servers on 5000–5999", and
5432 is inside that range. The accept is correct, and the packet never gets to
it.

Nothing in `apps_to_db` hints at this, and nothing in the baseline mentions
Postgres. The conflict exists only along the path the packet actually takes,
which the trace prints and a printed ruleset doesn't.

## The fix

<details>
<summary>Solution</summary>

Record what the trace showed:

```
chain: baseline_cross_zone
handle: 26
```

Then let Postgres out of the baseline *before* the range drop, in the boot file:

```
chain baseline_cross_zone {
    ip daddr 10.92.2.10 tcp dport 5432 return
    tcp dport 5000-5999 counter drop
    ...
}
```

```
$ systemctl reload fw2-firewall.service
$ ip netns exec apps nc -w3 10.92.2.10 5432
db-postgres-ok
```

`return` sends the packet back to `from_apps`, which jumps to `apps_to_db`, and
that chain's accept applies, so the zone-pair chain still decides. The reload
also removes your trace chain: the file starts with `destroy table inet fw2`.

</details>

## What not to do

**Delete the range rule.** Postgres works, and so does the dev server on 5001,
because `apps_to_db` accepts unprivileged ports for the db tier's exporters.
SEC-118 was the only thing keeping it shut.

**Add another accept in `apps_to_db`.** The packet never reaches that chain.
Adding rules where they look right, rather than where the packet goes, is how
rulesets grow to forty rules.

**Leave the trace rule in.** Tracing costs performance and fills the monitor
for whoever runs it next. Take it out, or reload from the file.

## Carrying this forward

When a ruleset is longer than a screen, don't read it to find a drop. Trace one
packet: `nftrace` in a high-priority prerouting chain, then `nft -a monitor
trace`. For iptables-nft rulesets, `xtables-monitor --trace` with a `-j TRACE`
rule in the raw table does the same. The answer is a chain and a handle, not a
guess.
