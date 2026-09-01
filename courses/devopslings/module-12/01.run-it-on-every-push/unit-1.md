---
title: "the workflow exists, and it has never run"
---

## The situation

`checkout` has a CI workflow. It was added during onboarding, it was reviewed,
it was merged, and in four months it has never produced a red build. It has
never produced a green one either:

```
$ cat .forgejo/workflows/ci.yml
name: ci

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm test || true
```

Nobody is lying about having CI. The file is there, the syntax is valid, and
the pipeline page is empty.

There are two separate problems in those ten lines, and fixing either one alone
leaves you with a pipeline that still tells you nothing.

## Your objectives

1. Make every push to the repository start a run.
2. Make the run's result depend on whether the tests pass.

Leave `runs-on: docker` as it is — that line is correct here, and the next
lesson is about what happens when it is not.

## What you're being graded on

That the tip of `main` has a finished run reporting success. Then the grader
pushes a commit whose tests genuinely fail and requires the pipeline to report
that as a failure — because a pipeline that cannot go red has not told you
anything when it is green. It removes that commit afterwards.

<details>
<summary>Hint 1 — what starts a run</summary>

`on:` lists the events that trigger the workflow, and it is the whole list.
`workflow_dispatch` means one event: a human pressing "Run workflow" in the web
UI. No push, however important, is on that list.

```yaml
on: [push]
```

Push something and watch <http://localhost:3000/devops/checkout/actions>.

</details>

<details>
<summary>Hint 2 — what makes a run red</summary>

Now make the tests fail on purpose — break an assertion in
`src/pricing.test.js`, commit, push — and look at what the pipeline says about
that commit.

It says success. Work out what `npm test || true` exits with when `npm test`
exits with 1.

</details>

<details>
<summary>Hint 3 — the chain from a command to a badge</summary>

A step runs a command. The step passes if the command exits 0 and fails
otherwise. A job fails if any step fails, and the run's status is the job's
status. That chain is the entire mechanism, and `|| true` cuts it at the first
link: the shell exits 0 whatever the command did.

</details>

<details>
<summary>Solution</summary>

```yaml
name: ci

on: [push]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

```
$ git commit -am "run the tests on every push, and let them fail" && git push
```

The push itself produces the first real run. To convince yourself it means
something, break a test and push again — the run goes red, and the commit gets
a red mark next to it in the forge. Then put it back.

### The part worth remembering

**A pipeline is only as informative as its ability to fail.** Green means "the
commands I ran exited 0". If nothing can exit non-zero, green means "the
pipeline ran", which is a fact about the pipeline and not about the code. The
first thing to do with any new pipeline is make it fail on purpose, once, so
you know the wire is connected.

`|| true` is not the only way to cut that wire, but the shell already closes two
of the gaps you might expect. A `run:` step executes under `bash -e -o pipefail`
here and on GitHub, so a multi-line script stops at its first failing command
rather than running on to a successful one, and `npm test | tee log.txt` reports
the test's failure rather than `tee`'s success. Both are worth knowing as facts
rather than as fears — measured on this runner, both go red.

What does still cut it:

- **`|| true`**, and its quieter twin `|| :`.
- **`continue-on-error: true`** on a step or job, which is sometimes exactly
  right and should be a decision rather than a leftover.
- **`shell: sh`**, which loses `pipefail` — the pipe case comes back.
- **A command that fails without saying so**: a test runner that exits 0 when it
  found no tests to run, a linter whose reporter swallows its own status. Here
  the exit code is 0 and the step is right to believe it. `green-pipeline`,
  three lessons on, is an entire exercise built on that one.

On triggers, `on:` is a list of events and the common ones are worth knowing as
a set:

- `push` — every push to any branch, unless you narrow it with `branches:`.
- `pull_request` — the merge result rather than the branch tip, which is what
  you want as a merge gate.
- `schedule` — cron, for things that should run whether or not anyone commits.
- `workflow_dispatch` — a human pressing a button. Useful as an *addition* to
  the others, when you sometimes need to re-run something by hand; the mistake
  here was having it as the only one.

They combine, and most real workflows use two or three:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

This is GitHub Actions syntax, running on Forgejo's `act_runner`. Everything in
this file works unchanged in `.github/workflows/`.

</details>
