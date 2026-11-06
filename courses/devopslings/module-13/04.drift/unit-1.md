---
title: "someone deleted cache by hand, and nothing noticed"
---

## The situation

`/root/infra` manages a network and three containers: `web`, `cache` and
`worker`. Someone deleted `cache` by hand, the way people click "delete" in a
cloud console. Nothing failed and nothing alerted. You only know because a
user complained.

```
$ docker ps --format '{{.Names}}'
worker
web
```

The first guess is to run `tofu apply` again and hope. Here, apply would put
`cache` back. But "hope" is the problem in two ways. You would be applying
without knowing what else has drifted, or what apply will do about it. And
nothing will tell you next time either. Drift is only found when someone
happens to look.

## Your objectives

1. See the drift in a plan, then put the infrastructure back to what the code
   describes. The code is right.
2. Write `ci/drift-check.sh`. It must only look, and exit `0` when nothing has
   drifted, `2` when something has, and anything else when it could not check.
3. Add `.forgejo/workflows/drift.yml`, a job that runs the check on a schedule.

## What you're being graded on

The code must still declare all four resources, every container must be
running, and the plan must be clean.

Then the grader runs your check three times. Once on clean infrastructure,
where it must exit `0`. Once after it deletes `worker` itself, where it must
exit `2` and leave `worker` deleted. And once with the Docker daemon
unreachable, where it must exit something other than `0` or `2`. The grader
puts `worker` back afterwards.

Last, `drift.yml` must have a `schedule` trigger with a cron line and must run
the check.

<details>
<summary>Hint 1 — how a plan sees drift</summary>

Before planning, `tofu plan` refreshes. It asks the provider what every object
in state looks like right now. `cache`'s container ID no longer exists, so the
refresh drops it, and the plan compares the code with what is really there:

```
  # docker_container.cache will be created
```

To accept the deletion instead, so the state matches reality and the code is
ignored, there is `tofu apply -refresh-only`. That is the right tool when the
change by hand was intended and the code is about to follow. Here the code is
right, so it is the wrong tool.

</details>

<details>
<summary>Hint 2 — the exit code</summary>

A plain `tofu plan` exits `0` whether or not it found changes. So does a
`grep "No changes"` that treats every non-match as drift, until the day the
check cannot reach Docker and reports drift instead of "broken".

`tofu plan` has a flag that makes the exit code carry the answer: `0` no
changes, `1` error, `2` changes. That is exactly the contract the README asks
for.

Don't use `-refresh=false`. It skips the refresh step, which is the only part
that looks at the real containers.

</details>

<details>
<summary>Hint 3 — why not let CI apply</summary>

A scheduled `tofu apply -auto-approve` looks like the complete fix. It finds
drift and repairs it. But some drift is deliberate: a container stopped during
an incident, or a hotfix applied by hand at 3am. Auto-apply reverts those with
nobody watching. Detection opens a ticket, and a person decides.

</details>

<details>
<summary>Solution</summary>

```
$ tofu plan
  # docker_container.cache will be created
Plan: 1 to add, 0 to change, 0 to destroy.
$ tofu apply
```

`ci/drift-check.sh`:

```sh
#!/bin/sh
# Exit 0: no drift. 2: drift. Anything else: the check could not run.
# Read-only: plans, never applies.
tofu init -input=false >/dev/null || exit 1
exec tofu plan -input=false -lock=false -detailed-exitcode
```

`-lock=false` is safe here because a plan writes nothing. It also means a
scheduled check never blocks a real deploy that is waiting for the lock.

`.forgejo/workflows/drift.yml`:

```yaml
on:
  schedule:
    - cron: "*/30 * * * *"
jobs:
  drift:
    runs-on: iac
    steps:
      - uses: actions/checkout@v4
      - run: ci/drift-check.sh
```

### Drift is the normal case

Your code describes what you want. Reality is whatever happened last, whether
that was an apply, a person, an autoscaler or a failed disk. The two drift
apart all the time. A plan is the only tool that compares them, and it only
helps when someone runs it. Running it on a schedule turns drift from
something you find during an outage into a ticket with a diff attached.

</details>
