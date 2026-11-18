---
title: "Thirty services on a build that cannot fail"
---

## The situation

`devops/paved-road` is the platform's shared build, a composite action every
Node service calls after its clone step. Its v1 was written during a week of
flaky tests:

```yaml
run: npm test || echo "::warning::tests failed; not failing the build"
```

A service on v1 is green whatever its tests say. v2 is the same action
without the `||`, tagged and documented. Thirty services, `devops/svc-01`
to `devops/svc-30`, are still on v1.

The last time the platform retired a version, it sent an email with a date,
and on the date deleted the tag. Every build still on it failed at once, and
the platform team spent the day being the reason nobody could ship.

## Your objectives

1. Move all thirty consumers to `paved-road@v2`, everywhere they use it.
2. Do it without a red build on any consumer's `main`. A consumer's branches
   can be red; its main cannot.
3. Leave a check, `bin/v1-consumers` in `devops/paved-road`, that lists every
   repository still using v1 and exits non-zero when there is one.

## Getting started

```
git clone http://devops:devopslings@localhost:3000/devops/paved-road.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. Its API is under `/api/v1`: `GET /repos/search` lists
repositories, `GET /repos/{owner}/{repo}/contents/{path}` lists a directory,
and `GET /repos/{owner}/{repo}/commits/{sha}/status` is a commit's pipeline
result. Thirty clones are a loop, not an afternoon.

## What you're being graded on

- Every one of the thirty has no workflow that mentions `paved-road@v1`, and
  its `ci.yml` builds with `paved-road@v2`.
- None of them changed its test file or `package.json`.
- No pipeline run on any consumer's `main` has failed, and each one's latest
  commit on `main` is green.
- `paved-road@v2` still fails a service whose test fails (the check pushes
  one).
- `bin/v1-consumers`, run from the root of `paved-road` in the runner's job
  image with `FORGE_URL`, `FORGE_USER` and `FORGE_PASSWORD` set, exits 0 now.
  Then the check creates a new repository that uses v1 only in a release
  workflow, and it must exit non-zero and name that repository.

A red run on `main` stays in its history, so a mistake there means resetting
the lesson.

<details>
<summary>Hint 1 — what v2 will find</summary>

v1 has been hiding test results. Some of the thirty have tests that fail, and
the first v2 build on those is red. Find out which ones before main does: a
push to a branch runs the pipeline too.

</details>

<details>
<summary>Hint 2 — the references are not all alike</summary>

`ci.yml` is not the only workflow, and `@v1` is not always written the same
way. Search every file under `.forgejo/workflows/` for `paved-road@v1`, which
is also what the check has to do. Build the check first, and its output is
your list of repositories to move.

</details>

<details>
<summary>Hint 3 — the order of a migration</summary>

For each consumer: a branch with the change, wait for its pipeline, and push
the branch to main only when it is green. For the ones that are red, the
failing test is telling the truth about the code; fix the code on the
branch, then merge.

</details>

<details>
<summary>Solution</summary>

`bin/v1-consumers` walks `GET /api/v1/repos/search` page by page, lists each
repository's `.forgejo/workflows/`, and greps every file for
`paved-road@v1\b`. It prints `owner/repo: path` for each hit and exits 1 if
there was any.

The migration, per consumer it lists:

```
git checkout -b paved-road-v2
sed -i -E 's/paved-road@v1\b/paved-road@v2/' .forgejo/workflows/*
git commit -am "build with paved-road@v2" && git push origin paved-road-v2
# wait for the branch's status; if red, fix the code it caught and push again
git push origin paved-road-v2:main
```

Three services, `svc-07`, `svc-19` and `svc-26`, go red on their branch:
`total()` ignores `qty`, and their test has said so since v1 was written. The
fix is `sum + i.price * i.qty`. Then `bin/v1-consumers` prints
`no repository uses paved-road@v1`.

### Why the date-and-email retirement fails

A deadline moves the cost of the migration onto the day of the deadline, for
everyone at once, and the platform's flaw becomes thirty teams' outage. It
also assumes the change is mechanical. This one is not: v1's flaw hid three
real bugs, and moving those services was a code fix, not a version bump.
Run on a branch, v2 told you which three before anybody's main did.

### Why the check matters more than the migration

The thirty is the count today. A team copies an old workflow next quarter,
and the count is one again. A check that finds consumers, rather than a list
of the thirty, is what makes "nobody is on v1" a fact you can recheck. Run it
in CI against the forge, and the day it reports zero is the day the v1 tag
can go. Deleting a tag that nothing uses causes no outage.

### What platforms do at scale

The same shape with more tooling: a codemod or a bot (Renovate, Dependabot,
an in-house one) opens the change as a pull request in every repository, CI
runs v2 on the PR, the green ones merge themselves, and the red ones become
a list of teams with a specific failing test to look at. The platform team
fixes what it can and asks owners about the rest.

</details>
