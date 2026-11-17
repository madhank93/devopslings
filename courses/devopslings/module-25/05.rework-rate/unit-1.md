---
title: "Rework rate: which deploys were fixing the last one?"
---

## The situation

DORA's 2024 and 2025 reports added a fifth measure, **rework rate**: the share
of deployments that were unplanned and made to fix a problem users hit in
production. It catches what change failure rate misses, because it does not
depend on somebody filing an incident.

The same twelve weeks of checkout. A `git log --oneline | grep -i fix` finds
plenty, and almost none of it is rework.

## Your objectives

1. Find the production deployments that were rework.
2. Give their tags and the rework rate over all production deployments.

Write them in `scratch/rework-rate/answer.txt`.

## What you're being graded on

The set of deployments must be exact: none missing, none extra. The rate must
be within half a percentage point.

<details>
<summary>Hint 1 — what the commits say about each other</summary>

Fixes in this repository say what they fix. A `Fixes: <sha>` trailer, or a
revert's `This reverts commit <sha>.`, names the commit being repaired:

```
git log --format='%h %s%n%b' | grep -B1 -E '^(Fixes: |This reverts commit )'
```

The question for each one is whether the commit it names had already reached
production when the fix was deployed.

</details>

<details>
<summary>Hint 2 — reached production by when</summary>

`git merge-base --is-ancestor <fixed> <previous deploy's commit>` exits 0 when
the fixed commit was already in the deploy before the one carrying the fix.

</details>

<details>
<summary>Solution</summary>

```bash
prev=""
git for-each-ref --sort=taggerdate --format='%(refname:short) %(*objectname)' refs/tags/deploy/production |
while read -r tag commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    fixed=$(git log -1 --format=%b "$c" |
      sed -n 's/^Fixes: \([0-9a-f]*\).*/\1/p; s/^This reverts commit \([0-9a-f]*\)\..*/\1/p')
    if [ -n "$fixed" ] && [ -n "$prev" ] && git merge-base --is-ancestor "$fixed" "$prev"; then
      echo "$tag"; break
    fi
  done
  prev=$commit
done
```

```
rework-deploys=414,444,462,478,489
rework-rate=17.9
```

Five of 28. Four of them are the incidents from change-failure-and-fdrt. The
fifth, deploy/production/462, is the delivery-estimate fix: customers reported
Friday orders promised for Sunday, it went out off the train the same
afternoon, and nobody opened an incident.

What looks like rework and is not:

- **Fixes caught before they shipped.** Two release trains carry a feature and
  the fix for it together. The bug never reached a customer.
- **Commits that say "fix"** about a flaky test or a typo. Nothing was broken
  in production.
- **Off-train deploys that fix nothing**: the retries of the two aborted
  attempts, and the Friday launch somebody scheduled. Unscheduled is not the
  same as unplanned-because-broken.

### The part worth remembering

**Rework is a property of a deployment, decided by what it repaired.** That
needs two things the history has to provide: a link from the fix to what it
fixes, and the deploy events to say whether the broken change had shipped.
Teams that fail this metric usually fail it on the first: fixes that do not say
what they fix cannot be counted by anything but a person reading every commit.

</details>
