---
title: "seven of eight servers, and a flag that meant something else on the eighth"
---

## The situation

On 1 August 2012 Knight Capital's order router, SMARS, sent millions of
orders into the market in about 45 minutes while handling 212 ordinary
customer orders. Knight lost more than $460 million. Nothing about the
day's market was unusual. One of SMARS's eight servers was not running what
the other seven were.

This is a replay, built from the SEC's order against Knight (Release No.
34-70694, 16 October 2013). `incident.md` in the lesson directory lists what
the order records, with its paragraph numbers. `fleet/` is the eight servers
as they stood that morning, reduced to the one routine that mattered: what a
server does with a parent order that carries the flag.

The rest of this module asks how a system behaves when something under it
fails. Here nothing failed. Every server did exactly what its code said, and
the market got exactly what SMARS sent. What failed was knowing which code
was where.

## Your objectives

**Reconstruct it.** Find the server that diverged, using the fleet rather
than the story. `./replay.sh` sends one flagged order to every host.
Then replay the response: during the incident Knight took the new code back
off the servers that had it. Copy `fleet/`, do the same to the copy, and run
`./replay.sh` against it.

**Gate it.** `preflight.sh` runs before SMARS is allowed to trade, and it
passed that morning. Make it refuse: given a fleet directory, exit 0 only
when it is safe to turn the flag on, and otherwise exit non-zero naming every
host that is not safe.

**Explain it** in `answers/reconstruction.md`: which host, what the flag did
there, and what the rollback did.

## What you're being graded on

Your `preflight.sh`, run against fleets the grader builds. The incident fleet
must be refused with `smars-8` named and no healthy host named. A healthy
fleet must be let through. And it must also refuse fleets that went wrong in
other ways: a deploy log that says every copy succeeded when one did not, a
copy that stopped part-way, a host that cannot be inspected, and a deploy
that never ran anywhere.

Then the reconstruction. `divergent_host` is checked exactly. `root_cause`
and `rollback` are each read as one or two sentences and checked for the
mechanism the SEC order records. Blaming the technician, blaming the new
code, blaming the market, or pasting a list of terms all fail, each with its
own reason.

<details>
<summary>Hint 1 — where to look</summary>

`fleet/deploy.log` is what the deployment says it did. `fleet/hosts/` is what
it actually left behind. They are different evidence, and only one of them
was going to trade at 09:30.

`diff -r fleet/release fleet/hosts/smars-1` is the whole comparison. Run it
for every host in `fleet/inventory`.

</details>

<details>
<summary>Hint 2 — a stale server is not enough on its own</summary>

A server running last week's build is an ordinary thing. It usually costs
nothing, because last week's build was fine last week.

Read `fleet/hosts/smars-8/smars/on_flag` and `fleet/release/smars/on_flag`
side by side. The question is not "why was smars-8 old" but "why was old
dangerous *on this particular day*". The answer involves the flag, and what
it used to switch on.

</details>

<details>
<summary>Hint 3 — what makes a gate a gate</summary>

Compare each host against the release, not against the other hosts, and not
against the log. Hosts can agree with each other and all be wrong. A log
records what the deploy tried.

Work from the inventory, so a host you cannot reach is a refusal rather than
a host your loop never visits. And check that each file in the release is
present on the host, not only that the host's files match.

</details>

<details>
<summary>Solution</summary>

`smars-8` is the divergent host. The deployment copied the RLP build to seven
servers and not the eighth (SEC order ¶15), so smars-8 still had Power Peg:
code Knight had stopped using in 2003, still present and callable, whose
cumulative-quantity tracking had been moved in 2005 without Power Peg being
retested (¶13, ¶14). The new RLP code repurposed the flag that used to
activate Power Peg. On seven servers the flag meant RLP. On smars-8 it meant
Power Peg, which could no longer see that a parent order had filled, so it
kept sending child orders (¶16).

The gate compares every host in the inventory against the release, and
fails closed:

```bash
#!/usr/bin/env bash
set -u
fleet=${1:?usage: preflight.sh FLEET_DIR}
[ -s "$fleet/inventory" ] || { echo "REFUSE: no inventory"; exit 1; }
bad=0
while read -r host; do
  [ -n "$host" ] || continue
  if [ ! -d "$fleet/hosts/$host" ]; then
    echo "REFUSE $host: cannot inspect it"; bad=1
  elif ! diff -r "$fleet/release" "$fleet/hosts/$host" >/dev/null 2>&1; then
    echo "REFUSE $host: does not match release/"; bad=1
  fi
done < "$fleet/inventory"
[ "$bad" -eq 0 ] && echo "every host matches release/ — safe to trade"
exit "$bad"
```

The rollback: during the response Knight uninstalled the new RLP code from
the seven servers where it had been deployed correctly. Orders were still
arriving with the flag set, so those seven now ran Power Peg too. The SEC
order says this "worsened the problem" (¶27). Replaying it against a copy of
`fleet/` shows eight runaway servers instead of one.

### The part worth remembering

**A reused flag gives one bit two meanings.** Its meaning depends on which
build reads it, and a fleet that is part-way through a deploy runs two
builds. Reusing the flag was safe only on the assumption that the old meaning
had been removed from every server. Nothing checked that. A new flag would
have done nothing at all on the stale server.

**Dead code is not dead while it is callable.** Power Peg was unused for nine
years and still reachable from production. Its safety check had been broken
in 2005, and nobody found out, because nobody ran it. Code you are not
running is code you are not testing. Delete it. Don't leave it switched off.

**A deploy log is not an inventory.** The log lists what the deployment
tried. The servers hold what it actually did. A gate has to ask the servers,
compare them with the release rather than with each other, and treat a
server it cannot ask as a refusal.

**The signal existed and nobody was listening.** From 08:01, before the open,
Knight's own systems sent 97 automated e-mails about SMARS reporting "Power
Peg disabled" (¶19). They were not designed as alerts and generally were not
read. A message that only matters on the one day it is sent will not be read
on that day unless something forces it to be.

**Rolling back is a deploy too.** "Roll back" feels like the safe option.
Here it put the old meaning of the flag back onto the seven servers that had
been safe. A rollback is a change to a fleet in an unknown state, and it
needs the same question asked first: what will each server do with the
traffic it is getting right now? The SEC also found that Knight had no
supervisory procedures for incident response, no procedure to halt SMARS in
response to its own aberrant activity, and no firm-wide capital threshold
linked to an automated control that would stop orders (¶21, ¶22, ¶27).

**"The technician missed a server" is true, and it is not the root cause.**
The order records the missed copy, and in the same paragraph says no second
technician reviewed the deployment and no written procedure required one
(¶15, ¶26). Any process with an unchecked manual step will eventually miss
that step. What made the miss cost $460 million was the reused flag, the
callable dead code, and having no gate between the deploy and the open.

</details>
