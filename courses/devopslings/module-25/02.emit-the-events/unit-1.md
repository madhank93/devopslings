---
title: "The pipeline records the deployment, and it only remembers the last one"
---

## The situation

checkout deploys on every push to `main`. Somebody wanted the dashboard to
show what production is running, so the pipeline got one more step:

```yaml
- name: record the deployment
  if: always()
  run: |
    git tag -f production
    git push -f origin production
```

It does what it was asked. `production` always points at the commit that is
running. Now the team wants deployment frequency and lead time, and that step
cannot give them either: it is one ref, moved on every run. Yesterday's
deployments are gone, and none of them has a time of its own.

## Your objectives

1. Every successful deploy leaves its own record: which commit, and when the
   deploy ran.
2. A deploy that fails leaves no record at all, and the run goes red.

Keep the records as tags under `deploy/production/`, one per deployment, so
the rest of this module can read them the way it reads checkout's history.

## Getting in

```
git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

Runs are at <http://localhost:3000/devops/checkout/actions>. `deploy.sh`
stands in for the real deploy: it ships only if `healthcheck.sh` exits 0.

## What you're being graded on

The check pushes three commits to `main` and watches each run. The first two
must go green and each must leave its own tag under `deploy/production/`
pointing at it, dated within a couple of minutes of when the deploy ran. The
first tag must still be there after the second deploy. The third commit breaks
the health check: its run must go red and leave no tag. Afterwards the check
puts `main` back where you left it and removes its own tags.

<details>
<summary>Hint 1 — a tag that has a date</summary>

A lightweight tag (`git tag name`) is a name for a commit, nothing more. The
only date near it is the commit's, which is when the change was written. An
annotated tag (`git tag -a name -m ...`) is an object of its own, with a
tagger and a date: the moment the tag was made.

</details>

<details>
<summary>Hint 2 — one name per deployment</summary>

`${{ github.run_number }}` is different on every run. A tag named after it is
never overwritten, so `-f` is no longer needed — and if a push ever does need
`-f`, the name is wrong.

</details>

<details>
<summary>Solution</summary>

```yaml
- run: sh deploy.sh
- name: record the deployment
  run: |
    tag="deploy/production/${{ github.run_number }}"
    git -c user.name=pipeline -c user.email=pipeline@example.invalid \
      tag -a "$tag" -m "deploy checkout to production" \
      -m "commit: ${{ github.sha }}"
    git push origin "$tag"
```

Three changes, one for each thing the old step got wrong:

- **`if: always()` is gone.** A step runs only when every step before it
  succeeded, which is exactly the condition "the deploy happened". With
  `always()`, a failed deploy was recorded as a deploy: it inflated deployment
  frequency, and because nothing failed *in production*, it never showed up in
  change failure rate either.
- **`-a`.** The tag carries its own date, the deploy time. Lead time is the
  gap between a commit's date and that date, so without it there is no lead
  time to measure.
- **A unique name.** Deployment frequency is a count, and a count needs one
  record per thing counted. The moving `production` tag answers "what is
  running now", which is a different question. Keep it as well if the
  dashboard wants it — next to the events, not instead of them.

### The part worth remembering

**Every DORA metric is computed from deployment events, so the pipeline has to
emit them, at the moment the deploy succeeds, from the step that knows it
succeeded.** Reconstructing them afterwards from logs or from what is running
gives you the state, not the history.

A tag is the smallest thing that works here, and it is what the rest of the
module reads. At work the event usually goes somewhere with a query language —
a `deployments` table, a deployment API, an event in your metrics store — and
it carries the same three facts: what was deployed, where, and when.

</details>
