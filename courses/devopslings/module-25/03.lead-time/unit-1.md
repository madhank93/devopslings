---
title: "Lead time for changes, measured from every commit"
---

## The situation

The dashboard says checkout's lead time for changes is about three and a half
hours. It got that by taking each production deploy and subtracting the date
of the newest commit in it.

The newest commit in a deploy is the one that waited least. Everything before
it in the same deploy sat on `main` longer, and some of it sat there for a
long time. The team suspects the number is flattering; you have the same
twelve weeks of history as in count-your-deploys to find out by how much.

## Your objectives

1. Give every commit that reached production its lead time: from its commit
   date to the date of the first successful production deploy that carried it.
2. Report how many commits you measured, the median, the 90th percentile, and
   the deploy that carried the commits that waited longest.

Write them in `scratch/lead-time/answer.txt`.

## What you're being graded on

The commit count must be exact. The median and p90 must be within 5% of the
values computed from the history; nearest-rank and interpolated percentiles
are both accepted. The slowest deploy must be the one the longest-waiting
commits actually shipped in.

<details>
<summary>Hint 1 — which commits a deploy carried</summary>

A deploy carries every commit reachable from its commit that the previous
successful production deploy did not:

```
git rev-list <this deploy's commit> ^<previous deploy's commit>
```

`git for-each-ref --sort=taggerdate --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production`
lists the deploys oldest first, with the commit each one points at.
Remember which of them succeeded.

</details>

<details>
<summary>Hint 2 — percentiles in a shell</summary>

Sort the lead times, then the p-th percentile by nearest rank is the value at
position `ceil(p × n)`. `sort -n | awk` is enough.

</details>

<details>
<summary>Solution</summary>

```bash
prev=""
git for-each-ref --sort=taggerdate \
  --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production |
while read -r tag at commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    echo "$((at - $(git log -1 --format=%ct "$c"))) $tag"
  done
  prev=$commit
done | sort -n > lead
```

```
commits=182
median-hours=27.8
p90-hours=121
slowest-deploy=deploy/production/453
```

The dashboard's 3.5 hours was real: it is the median of 28 numbers, one per
deploy, each measuring the commit that waited least. Measured per change, the
median is a day and the 90th percentile is five days.

deploy/production/453 is the first deploy after the change-freeze week. Nothing
shipped for a week and a half, and the commits written at the start of the
freeze waited eleven days. The median does not move much for one bad week. The
p90 does, which is the reason to report it.

### The part worth remembering

**Lead time is a property of a change, not of a deploy.** DORA measures it from
commit to running in production, for each change, and a team's lead time is
that distribution. Measure from the deploy's newest commit and you have built a
metric that cannot see batching, which is the main thing that makes lead time
long.

**Report a distribution.** A median says what a typical change experiences. A
high percentile says what the unlucky ones do, and the unlucky ones are what a
change freeze, a broken pipeline or a slow review queue produce. The mean is
the worst of the three: one long week drags it a long way while describing no
change that actually happened.

</details>
