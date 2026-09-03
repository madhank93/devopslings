---
title: "production is running a commit that is not on main"
---

## The situation

Yesterday's incident went like this. Someone cut `hotfix/pricing` off an older
commit, fixed the rate, and pushed. The hotfix branch deploys straight to
production — that path was added during a previous incident, and it stayed,
because the whole point was not having to wait for a merge.

While that deploy was running, a merge landed on `main`, and `main` deploys to
production too. The hotfix carried a schema change, so its deploy ran migrations
and took longer. It finished second.

Both jobs write the same tag:

```yaml
docker build --build-arg GIT_SHA="${{ github.sha }}" -t "${IMAGE}:live" .
docker push "${IMAGE}:live"
```

Ask production what it is running:

```console
$ curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    http://127.0.0.1:5000/v2/checkout/manifests/live
# → config blob → "git.sha": "…"
```

That commit is not on `main`. Everything merged since the hotfix branched is not
in production, and nothing went red.

## Your objectives

1. Make production run a commit that is on `main`.
2. Keep deploying — a pipeline that no longer ships is not a fixed race.

## What you're being graded on

The grader pushes a change to `main` and requires it to reach production. Then
it pushes a branch under `hotfix/` and requires production to still be running
main's commit. It deletes the probe branch and force-pushes `main` back
afterwards.

<details>
<summary>Hint 1 — count the writers</summary>

`:live` is one mutable pointer. Two triggers can write it:

```yaml
on:
  push:
    branches: [main, 'hotfix/**']
```

Two writers to one location, no ordering between them, and the winner is
whichever finishes last. Which is not the same as whichever was newest — a
deploy that runs migrations takes longer, so the change that most needed care
is the one most likely to land on top of something newer.

</details>

<details>
<summary>Hint 2 — the answer you would reach for on GitHub does not work here</summary>

On GitHub Actions this is what `concurrency` is for:

```yaml
concurrency:
  group: production
  cancel-in-progress: false
```

**Forgejo 11 with act_runner v9.1.1 does not implement it.** Measured while
writing this lesson: with that exact block, at workflow level and at job level,
two deploys still overlapped — one ran 20:19:14→20:19:59 and the other started
at 20:19:16, inside that window. It is accepted, parsed, and ignored.

Learn the block, because it is the right answer on GitHub. Do not use it as the
answer here.

</details>

<details>
<summary>Hint 3 — do not fix it by making the hotfix deploy faster</summary>

Dropping the migration step closes the window this time. The window is a
property of the two jobs' relative durations, and those change every time
anybody edits either one. A fix that depends on a build staying fast is a fix
with an expiry date on it.

The question is not "how do I make the race less likely" but "why are there two
ways to write production".

</details>

<details>
<summary>Solution</summary>

One trigger:

```yaml
on:
  push:
    branches: [main]
```

That is the whole change. `main` is the only ref that can write `:live`, so
there is no second writer to race with, and an urgent fix reaches production the
way every other change does — by being merged.

### The part worth remembering

**An environment is a single mutable variable, and every deploy path is a
writer to it.** Races between deploys are not really CI problems; they are the
ordinary shared-mutable-state problem wearing a pipeline. The count that matters
is how many refs, workflows and humans can write the thing that says what is
live. Getting that count to one is worth more than any amount of locking around
a count of two.

**Last-writer-wins is not newest-wins.** The intuition that the most recent push
ends up live is only true when every deploy takes the same time, and they never
do — the deploys carrying migrations, asset builds or extra verification are
exactly the slow ones, and they are also the ones whose content you least want
silently reverted. This is why "just merge more slowly" fails as a policy: it
addresses arrival order, and arrival order was never what decided the outcome.

**The emergency path is how this gets built, every time.** Nobody adds a second
deploy trigger on a calm afternoon. It arrives at 3am with a good reason, and
then it is load-bearing and unexamined. The fix is not to have no emergency
path but to make the emergency path *faster on the same road* — a merge that
skips the queue rather than a branch that skips the merge. If an urgent change
cannot be merged in the time an incident allows, the thing to fix is the merge,
not to build a bypass around it.

**Watch out for the protection that only looks like protection.** Forgejo
auto-cancels a superseded run on the *same ref*: push twice to `main` quickly
and the first run is cancelled, so two merges to main genuinely cannot race
here. That is real, and it is per-ref — it does nothing between `main` and
`hotfix/pricing`. A safety property that holds for the case you tested and not
the case you shipped is worse than none, because it is why nobody looked.

**Where this goes next.** Serialising is the floor, not the ceiling. A deploy
that reads the currently-live revision and refuses to overwrite something newer
— compare-and-swap rather than blind write — survives cases that ordering alone
does not, including a job resumed after a long pause. It is also the shape that
lets a deploy be safely retried, which is the property you want at 3am.

</details>
