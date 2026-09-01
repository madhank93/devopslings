---
title: "the required check is green and one of the shards is red"
---

## The situation

The suite is split into three shards so it finishes in a third of the time.
Branch protection wants one required check rather than three, so there is a
summary job called `gate` that waits for the matrix:

```yaml
  gate:
    runs-on: docker
    needs: [test]
    if: always()
    steps:
      - run: echo "all checks complete"
```

Look at a run:

```
ci / test (unit) (push)          success
ci / test (contract) (push)      success
ci / test (integration) (push)   failure
ci / gate (push)                 success
```

The gate is the check that decides whether a pull request can merge, and it has
never been anything but green.

There is a second thing going on, and the two are tangled. The integration
shard talks to a service that is not always up when the job starts, so it fails
on its first attempt and passes if you re-run it. That flakiness is why nobody
looked hard at the red shard: it is usually the flaky one, and it is usually
fine.

## Your objectives

1. Make `gate` reflect what the shards actually did.
2. Stop the flaky shard from turning a healthy commit red — without hiding a
   shard that genuinely fails.

Keep the matrix, and keep a check called `gate`: the branch requires that name,
and collapsing three shards into one job gives up what the shards are for.

## What you're being graded on

That `gate` is green on the current commit, whose code is fine, despite the
integration shard's first attempt failing. Then the grader pushes a commit with
a failing assertion in the contract shard and requires both that shard and
`gate` to report failure. It force-pushes the repository back afterwards.

<details>
<summary>Hint 1 — what `needs` actually does</summary>

`needs: [test]` says *run after* `test`. It does not say *run only if `test`
succeeded* — that is the default behaviour it happens to come with, and
`if: always()` overrides exactly that.

So the gate runs after the matrix, whatever the matrix did, and then runs a step
that cannot fail. Nothing in the job ever consults the result.

The result is available:

```
${{ needs.test.result }}
```

For a matrix job it is one value for all shards: `success` only if every shard
succeeded.

</details>

<details>
<summary>Hint 2 — do not fix it by deleting `always()`</summary>

Dropping `if: always()` makes the gate skip when the matrix fails, and a
*skipped* required check is not a failed one — on most forges a skip is neutral
and a pull request with a neutral required check is not blocked. You want the
gate to run and fail, not to be absent.

Keep `if: always()`, and make the step's exit status depend on the result.

</details>

<details>
<summary>Hint 3 — the flaky shard</summary>

Fix the gate first and push. Main goes red, because the integration shard fails
its first attempt — which is exactly the problem the old gate was hiding.

Retry it *inside the job*, so a flaky shard costs seconds instead of a red main:

```yaml
- run: |
    for attempt in 1 2 3; do
      if <the command>; then exit 0; fi
      echo "attempt ${attempt} failed"
    done
    exit 1
```

Three attempts at a test that is genuinely broken still fail three times, which
is the property that makes this a retry rather than a `|| true`.

</details>

<details>
<summary>Solution</summary>

```yaml
jobs:
  test:
    runs-on: docker
    strategy:
      fail-fast: false
      matrix:
        shard: [unit, contract, integration]
    steps:
      - uses: actions/checkout@v4
      - run: |
          for attempt in 1 2 3; do
            if node --test src/${{ matrix.shard }}.test.js; then
              exit 0
            fi
            echo "attempt ${attempt} failed"
          done
          exit 1

  gate:
    runs-on: docker
    needs: [test]
    if: always()
    steps:
      - run: |
          echo "test result: ${{ needs.test.result }}"
          test "${{ needs.test.result }}" = "success"
```

Two changes that solve two different problems. The gate now reads the verdict of
the thing it waited for. The matrix retries a shard up to three times, so the
integration suite's first-attempt failure costs a few seconds, and a real
failure still fails three times and reaches the gate.

### The part worth remembering

**`needs` is an edge in a graph, not an assertion.** It orders jobs and, by
default, skips the dependent when the dependency fails. `if: always()` removes
that default — which is often what you want for a summary or notification job —
and once you have removed it, nothing is checking anything unless you write the
check yourself. A summary job whose only step is `echo` is a green light wired
to nothing.

The states a `needs.<job>.result` can hold are `success`, `failure`,
`cancelled` and `skipped`, and only the first should let a merge through.
`test "${{ needs.test.result }}" = "success"` is the whole gate. Comparing
against `!= 'failure'` is the version of this bug that survives review, because
a cancelled or skipped matrix then reads as permission to merge.

**A skipped required check is not a failed one.** This is why the fix is not
removing `if: always()`: forges generally treat a skipped check as neutral
rather than blocking, so a gate that disappears when the matrix fails can be
*less* protective than one that runs and passes. Make it run, and make it fail.

**Retry and ignore are not the same thing**, even though both make a red shard
green. A retry runs the failing thing again and requires it to pass; a genuine
failure fails every attempt. `|| true` and `continue-on-error: true` accept the
first failure as a pass, so they cannot tell flaky from broken. Retries have
their own cost — they hide how flaky the suite actually is, so the flakiness
should be recorded somewhere (a log line per retry at minimum) rather than made
invisible.

**`fail-fast` is the other matrix control, and the default is not obviously
right.** `fail-fast: true` — the default — cancels the remaining shards as soon
as one fails, which saves runner minutes and means you learn about one failure
per push: fix it, push, discover the next. `fail-fast: false` runs everything
and shows the whole picture, which is usually what a test matrix wants and a
deploy matrix does not.

</details>
