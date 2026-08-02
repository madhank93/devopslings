---
title: "Your first pipeline, and why the runner disagrees with you"
---

## The situation

`devops/checkout` has a small module and three tests. Running them locally
works:

```
$ npm test
✔ applies a percentage discount
✔ a zero discount changes nothing
✔ rejects a nonsense percentage
```

There is no CI. Nothing runs those tests unless a human remembers to.

The code is fine and stays fine — this lesson is about the pipeline, not the
program.

## Your objectives

1. Add a workflow that runs `npm test` on every push.
2. Push it, and get a green run.

## Getting the repo

```
git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. Workflows live in `.forgejo/workflows/` (`.github/workflows/`
also works — Forgejo reads both).

## What you're being graded on

That a workflow file is pushed, that the push triggered a run, that a runner
picked the run up, and that it finished green.

The third one is where most people stop. It is possible to write a completely
valid workflow that no runner will ever execute, and the failure mode is that
nothing happens at all.

<details>
<summary>Hint 1 — the shape of a workflow</summary>

```yaml
name: test

on: [push]

jobs:
  test:
    runs-on: <something>
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

`actions/checkout` is not optional. Without it the job starts in an empty
working directory — the runner does not clone your code for you.

</details>

<details>
<summary>Hint 2 — the run says "Waiting to run" and never changes</summary>

Your workflow is valid. It was accepted, a run was created, and it is sitting
there.

A job is dispatched to a runner whose **labels** match its `runs-on:`. If no
registered runner advertises that label, the job is queued for a runner that
does not exist. There is no error, because as far as the forge is concerned
nothing has gone wrong yet — it is waiting, exactly as designed.

See what labels actually exist:

<http://localhost:3000/admin/actions/runners>

</details>

<details>
<summary>Hint 3 — where `ubuntu-latest` comes from</summary>

`ubuntu-latest` is a **GitHub-hosted** runner label. It works on github.com
because GitHub operates a fleet of machines carrying that label.

This forge has one self-hosted runner. It advertises what it was registered
with — nothing more. Copying a workflow from a GitHub repo and expecting
`ubuntu-latest` to resolve is the single most common first-day self-hosted
Actions problem.

</details>

<details>
<summary>Solution</summary>

`.forgejo/workflows/test.yml`:

```yaml
name: test

on: [push]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

```
git add .forgejo && git commit -m "run the tests on every push" && git push
```

<http://localhost:3000/devops/checkout/actions> goes green.

### The one line that mattered

```yaml
runs-on: docker
```

The runner in this stack was registered with `--labels docker:docker://node:22-bookworm,host:host`,
which declares two labels:

- **`docker`** — run the job inside a container built from `node:22-bookworm`
- **`host`** — run the job directly on the runner's host

`runs-on: docker` matches the first, so the job gets a container with Node 22
already installed, which is why `npm test` works without a setup step.

On GitHub you would write `runs-on: ubuntu-latest` and add
`actions/setup-node@v4`. Same workflow language, different fleet. That is the
one thing that does *not* transfer between a hosted and a self-hosted setup,
and it is worth knowing precisely because everything else does.

### Why a stuck job is worse than a failing one

A failing job sends you a notification and shows you a red X. A job that never
gets claimed produces neither. On a team, the usual sequence is: someone adds
CI, it silently never runs, and three weeks later a bug ships that the tests
would have caught. Nobody was ignoring a red build — there was no build.

If you take one habit from this lesson: after adding CI to a repo, watch the
first run go green with your own eyes. "The workflow is committed" is not the
same claim as "the tests ran".

### Two things to add next

- **A pull-request trigger.** `on: [push]` alone means the tests run *after*
  the merge. `on: [push, pull_request]` runs them on the branch, before it
  matters.
- **A cache.** This job installs nothing, but a real one would. Caching the
  dependency directory is usually the single biggest CI speed-up available.

</details>
