---
title: "one input, two subsystems, and a status page that needed the thing it reported on"
---

## The situation

On the morning of 28 February 2017, the S3 team was debugging a slow billing
system in us-east-1. An authorized engineer ran a command from an established
playbook to take a few billing servers out of service. One of its inputs was
wrong. The command removed a much larger set of servers, and those servers
supported the index and placement subsystems. Every GET, LIST, PUT and DELETE
in the region needs index. Both subsystems needed a full restart, and S3 in
us-east-1 could not serve requests until that restart finished, around four
hours later.

For the first two hours AWS could not update the per-service status on its
Service Health Dashboard, because the dashboard's admin console depended on
S3.

This is a replay, built from AWS's published summary
(<https://aws.amazon.com/message/41926/>). `incident.md` lists what the
summary records. The summary does not say what the wrong input was, so the
replay invents one: positions `3 54` instead of `3 4`.

## Your objectives

**Break the loop.** `status/console.conf` configures the dashboard's admin
console, and `./post-status.sh` posts through it. Make a status post succeed
when S3 is down in any one known region, including the region the post is
about.

**Bound the tool.** `remove-capacity.sh` does whatever its input says. Make
it refuse any request that would leave a subsystem below its minimum in
`fleet/minimums`, or take more than 2 servers out in one command. When it
refuses, it must exit non-zero and say why. It still has to do the ordinary
job.

**Explain it** in `answers/postmortem.md`.

## What you're being graded on

The console config is tested against an S3 outage in each known region in
turn.

Your `remove-capacity.sh` runs against fleets the grader builds:

- the ordinary request, which must still work;
- the morning's input;
- one-server requests that walk index down to its floor;
- a three-server request that is nowhere near any floor.

The two prose fields are each read as one or two sentences and checked
against the mechanism in the summary. Blaming the engineer, blaming billing,
blaming load, or pasting a list of terms each fails, with its own reason.

<details>
<summary>Hint 1 — what the console is standing on</summary>

Read `status/console.conf`. Then run `touch s3-outage/us-east-1` and post a
status. The console isn't broken. It is fine everywhere except the one
place it is needed.

Moving it to a different single region does not fix that. It only moves
which outage the console cannot report.

</details>

<details>
<summary>Hint 2 — what a bound is measured against</summary>

The minimum applies to what is *in service right now*, after this command,
not to the subsystem's full size. Two careful one-server commands can still
reach zero if each one is only checked against the size of its own request.

The per-command limit and the floor catch different things, and you need
both. The limit catches the big mistake. The floor catches many small,
correct-looking steps that add up to one.

</details>

<details>
<summary>Hint 3 — "be more careful"</summary>

Count how many times that playbook command has been run without incident,
and how many keystrokes each run takes. A mistake that happens once in some
large number of runs is not a failure of care. It is the error rate of
people typing, and better intentions do not change that rate.

What you can change is what the tool does with the mistake.

</details>

<details>
<summary>Solution</summary>

`status/console.conf`:

```
regions=us-east-1,us-west-2
```

`remove-capacity.sh` checks the whole request before it changes anything:

```bash
MAX_PER_COMMAND=2
reasons=$(awk -v a="$first" -v b="$last" -v max="$MAX_PER_COMMAND" '
  NR == FNR { min[$1] = $2; next }
  { if ($3 == "in") { up[$2]++; if (FNR >= a && FNR <= b) { take[$2]++; n++ } } }
  END {
    if (n > max) printf "would remove %d servers; at most %d per command\n", n, max
    for (s in take) if (up[s] - take[s] < min[s])
      printf "would leave %s at %d in service; minimum is %d\n", s, up[s] - take[s], min[s]
  }' "$fleet/minimums" "$fleet/servers")
if [ -n "$reasons" ]; then
  printf 'REFUSED %s-%s, nothing removed:\n%s\n' "$first" "$last" "$reasons" >&2
  exit 1
fi
```

These are the two changes AWS describes. The summary says the tool "allowed
too much capacity to be removed too quickly". AWS changed it to remove
capacity more slowly and added safeguards that stop removal when it would
take any subsystem below its minimum required capacity. AWS also changed the
dashboard's admin console to run across multiple AWS regions.

### The part worth remembering

**The fix for a mistyped input is in the tool, not the person.** The summary
describes an authorized engineer following an established playbook. Nobody
broke procedure. The procedure handed one human keystroke the power to remove a
significant portion of a region's index capacity, with nothing in between. "Be more careful"
does not change the error rate of typing. A floor and a rate limit change
what one error can cost. AWS also said it would audit its other operational
tools for the same kind of safety check, which is the right next step: if one
tool trusted its input this much, others probably do too.

**A monitor that shares a failure domain with what it monitors goes dark at
the worst time.** The dashboard exists for the moment S3 is down, and in this
design that was exactly the moment it could not be updated. The test for any
status page, alerting path or incident tool is: does it still work when the
thing it reports on is gone? Run that test on purpose before an incident runs
it for you. AWS fell back to its Twitter account and the dashboard's banner
text, which shows that the fallback channel has to exist before you need it.

**Capacity removal is a routine operation, and that is why it is dangerous.**
AWS says it relies on removing and replacing capacity as a core operational
process. An operation done that often, by many people, will eventually get a
wrong input. The guard has to live in the operation itself.

**Restarts you never practise get slower as you grow.** The summary says the
index and placement subsystems had not been completely restarted in the
larger regions for many years, and that restarting them, including the
metadata safety checks, took longer than expected. That turned a mistake
into hours of outage. AWS's longer-term answer was to split the index
subsystem into smaller cells. A smaller unit is faster to restart, and AWS
could test recovery on units of that size.

</details>
