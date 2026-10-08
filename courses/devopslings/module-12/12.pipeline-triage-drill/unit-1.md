---
title: "CI said the release passed, and staging is broken"
---

## The situation

```
$ sh scratch/pipeline-triage-drill/smoke.sh
smoke: FAIL
  3 x 9.50: total 9.5, expected 28.5
```

Release 1.4 went through the pipeline on main. Its gate passed and
`deploy-staging` went green. Staging is broken. That is the whole ticket, and it
will be the whole ticket every time you run this lesson, because the fault is
drawn at random from five. Each one is a different way a pipeline can approve
something it never checked.

The pipeline is `.forgejo/workflows/release.yml` in `devops/checkout`. A two-shard
test matrix (`cart`, `discount`) runs against cached dependencies. A `gate` job
is the one check the release waits on. `build` builds the image once, tags it
`checkout:<commit sha>` and pushes it. `deploy-staging` promotes that image to
`checkout:staging`. Staging *is* that tag. `smoke.sh` runs the release's smoke
test inside whatever image the tag points at.

You cannot memorise the answer. You can memorise the order you ask the pipeline
questions in.

## Why there is an order

A green tick is a claim with four parts: this commit's tests ran, they ran
against this commit's dependencies, they passed, and the thing they passed is
the thing that was deployed. Any one of those can be false while the tick stays
green. The cheapest question is about the last part, because the registry
answers it directly and in seconds. If staging is not running the tip of main,
nothing about the tip's test results matters yet.

## The ladder

**1. What is staging actually running?**

```console
$ accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
$ for tag in staging <tip sha>; do
    curl -sI -H "Accept: $accept" http://127.0.0.1:5000/v2/checkout/manifests/$tag \
      | grep -i docker-content-digest
  done
$ docker image inspect 127.0.0.1:5000/checkout:staging \
    --format '{{index .Config.Labels "git.sha"}}'
```

Every image carries the commit it was built from in its `git.sha` label. If that
is not the tip of main, ask where the commit came from: `git merge-base
--is-ancestor <sha> main` says whether it is an older commit on main, and `git
branch -r --contains <sha>` names the branch it is on. Run `docker pull` first,
because your local copy of a tag can be older than the registry's.

**2. Did any job in the run that deployed it fail?**

Open the run for the tip of main and read *every* job, not just the gate and
the deploy. A summary job is only as honest as whatever it reads. Read its log
and its `if:` too.

**3. Did the tests run at all?**

Open a test job's log and look for node's summary:

```
# tests 3
# pass 3
# fail 0
```

A test step that exits 0 without printing a summary did not run a test.
Compare the command in the workflow with the scripts in `package.json`.

**4. What did they run against?**

```
Cache restored from key: deps-Linux
```

or `Cache not found for input keys: …`, near the top of each test job. A cache
is only honest if its key changes whenever its contents should. Compare that key
with what the commit changed (`git show --stat`).

## Your objectives

1. Make staging pass its smoke test by repairing the pipeline, and the code
   where honest CI then shows you a real bug. Staging has to get there through
   the pipeline: push to main and let it deploy.
2. Write `scratch/pipeline-triage-drill/answers/triage.md` (the init prints the
   full path), in three lines:

   ```
   cause:     <what happened, in a few words>
   evidence:  <the log line, field or command that proved it>
   detection: <a signal, and the threshold at which it should have fired>
   ```

## What you're being graded on

**Staging works, and it works because of the pipeline.** The tip of main's
`deploy-staging` succeeded. Staging's manifest is exactly `checkout:<tip sha>`,
the image the build pushed. The grader runs its own copy of the smoke test in
it, so editing `smoke.sh` changes nothing.

**CI ran the suite.** The test jobs on the tip report five passing tests and
none failing.

**The tests are the tests.** Both test files on main are byte for byte the ones
release 1.4 shipped. Each fault then has a cheap way to make the ticket go quiet,
and each one is checked by a probe the grader pushes itself:

- a gate that still passes when a shard fails: the grader pushes a commit
  whose cart shard fails, and nothing may deploy it
- a cache key that still ignores the lockfile: the grader changes only
  `package-lock.json`, and the test jobs must not restore the old
  `node_modules`. A key that changes on every commit is rejected on sight,
  because it never saves an install
- staging written from a branch: the grader pushes `hotfix/grader-probe`, and
  staging must not move
- staging retagged by hand: the grader pushes to main, and staging has to move
  to the new commit's image by itself
- a second `docker build` in the deploy job is rejected in every variant

**The skipped test is still skipped.** Something in every log looks like the
reason nobody caught this. It is not, and it has to be there when you finish.

**You can name it.** `cause`, `evidence` and `detection` are each checked
against the fault that was seeded, and `detection` needs a number.

<details>
<summary>Hint 1 — the ladder, four questions</summary>

```console
$ docker pull -q 127.0.0.1:5000/checkout:staging
$ docker image inspect 127.0.0.1:5000/checkout:staging --format '{{index .Config.Labels "git.sha"}}'
$ git log -1 --format=%H origin/main
```

If those agree, open the tip's run at <http://localhost:3000/devops/checkout/actions>.
Check every job's colour, then the `# tests` summary in each test job's log,
then the `Cache` line above it.

</details>

<details>
<summary>Hint 2 — two of the five leave staging on the wrong commit</summary>

If staging's `git.sha` is not the tip of main, the tests are irrelevant: staging
is not running what they tested. Something wrote staging after main did, or
main's deploy promoted something other than what main's build pushed. The
first leaves a commit that is not on main. The second leaves an older commit
that is. `deploy-staging`'s log says what it pulled.

The other three leave staging on the right commit with the wrong code in it.
They differ in whether a test failed, never ran, or ran against something else.

</details>

<details>
<summary>Hint 3 — things that look like the fault and are not</summary>

- `live pricing service agrees with the cart # SKIP nightly only` is in every
  discount shard's log. It needs credentials only the nightly job has, and
  nothing about this release depends on it. Un-skipping it gives you a red
  build that has nothing to do with the ticket.
- `checkout:latest` is in the registry in every variant. It is left over from
  1.3's pipeline. It only matters if something still reads it.
- A run where every job is green tells you every *step* exited 0. It does not
  tell you any of them tested anything.

</details>

## What actually happened

One of five. Which one is in a digest in `scratch/pipeline-triage-drill/state`,
not a word. Reading it teaches nothing.

| Fault | What was done | The tell |
|---|---|---|
| tests | 1.4 renamed the npm script to `tests`, and the workflow runs `npm run test --if-present`, so the missing script is a silent pass. Its quantity fix reads `item.quantity` | test logs with no `# tests` summary |
| gate | `gate` runs with `if: always()` and only echoes. Same broken quantity fix | `test (cart)` red, and `gate`, `build` and `deploy-staging` green after it |
| cache | the cache key is `deps-${{ runner.os }}`, and 1.4 moved the lockfile to pricing-rules 2.0.0 | `Cache restored from key: deps-Linux` on a commit that changed the lockfile. The image installed 2.0.0 and CI tested 1.0.0 |
| race | `hotfix/discount-message`, cut from 1.3 and deploying with 1.3's pipeline, wrote staging after main did. 1.4's deploy has no `if:` on the ref | staging's `git.sha` is on the hotfix branch, not on main |
| stale | `deploy-staging` promotes `:latest`, which the 1.4 build no longer pushes | staging's `git.sha` is 1.3, and its digest is `:latest`'s, not `:<tip sha>`'s |

Forgejo differs from GitHub Actions here. A `concurrency:` group is the usual
answer to two refs deploying at once. Forgejo 11 parses it and ignores it, so
the race is closed the structural way: staging is written from main and from
nowhere else.

<details>
<summary>Solution</summary>

The reference solution walks the ladder and repairs at the first rung that
answers. Only one of these applies to any run:

```yaml
# stale: promote the image this run built, by its commit
docker pull -q "${IMAGE}:${{ github.sha }}"

# race: staging comes from main only
  deploy-staging:
    needs: [build]
    if: github.ref == 'refs/heads/main'

# gate: read the verdict, do not just wait for it
      - run: test "${{ needs.test.result }}" = success

# cache: the key changes when the lockfile does
          key: deps-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
```

For `tests`, name the script `test` in `package.json`. That turns CI red on the
quantity bug, which is `item.quantity` where the cart uses `qty`. For `gate`,
the same bug appears once the gate reads the shard. For `cache`, honest CI goes
red on pricing-rules 2.0.0, which drops `legacyRound` and raises the cap past
the 50% the tests hold, so the upgrade comes back out of the lockfile.

Then, for example:

```
cause:     the gate ran with if: always() and never read needs.test.result
evidence:  the tip's run: test (cart) failed, then gate, build and deploy-staging succeeded
detection: page on any deploy from a run with more than 0 failed jobs
```

</details>

## Carrying this forward

- **Ask what is deployed before asking whether it was tested.** A digest and a
  label answer that in seconds, and they make every later question either
  relevant or moot.
- **Green is a claim about exit codes.** A step that ran nothing, a gate that
  read nothing and a cache that restored the wrong thing all exit 0.
- **Count the tests.** "How many tests ran" is a number you can alert on, and
  it is the one that would have caught the quietest of these.
- **One road to staging, carrying one artefact.** A promote that reads a
  mutable tag, or a second ref that can deploy, puts something untested on the
  environment you trust.
- **Leave the skipped test alone until it is proven guilty.** A skip in every
  log is the most visible thing on the page, and here it is the least relevant.

Run the lesson again. The fault moves, and the ladder does not.
