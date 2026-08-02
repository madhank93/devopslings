---
title: "There's a deploy token committed in the workflow file"
---

## The situation

Someone needed a release out on a Friday, and the deploy step needed a token,
so the token went into the workflow:

```yaml
env:
  DEPLOY_TOKEN: "dpl_9f3c1a7e5b2d4086af11c7e390bb42d1"
```

It works. The pipeline is green. And the value is now in three places nobody
meant to put it:

- the repository, on `main`, in plain text
- every clone anyone has ever taken, and every fork
- the build log of every run, because `src/deploy.js` prints what it was given

You have been asked to fix it.

## Your objectives

1. The literal must be gone from the repository.
2. The pipeline must still deploy — a deploy that no longer authenticates is
   not a fix.
3. Whoever holds the old value must not be able to use it.

Objective 3 is the lesson. Objectives 1 and 2 are the part everyone does.

## Getting the repo

```
git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`.

## What you're being graded on

That the old value appears nowhere in the tree on `main`; that the workflow
sources the token from somewhere rather than carrying it; that the secret
actually exists on the repo; that the run after your change goes green; and
that the value the pipeline now deploys with is **not** the one that was
published.

The check establishes that last one from the build log of the run your fix
triggered. `src/deploy.js` prints a fingerprint — `sha256(token)[:12]` — and
the check compares it against the fingerprint of the published value. Leave
that line alone; it is the only thing standing between a graded rotation and
an ungraded one, for reasons hint 2 gets to.

<details>
<summary>Hint 1 — where a workflow gets a value it isn't allowed to contain</summary>

Forgejo stores per-repository secrets and injects them into a run. The
workflow refers to them by name:

```yaml
- run: npm run deploy
  env:
    DEPLOY_TOKEN: ${{ secrets.SOME_NAME }}
```

Set one at **Settings → Actions → Secrets** on the repo, or over the API:

```
curl -u devops:devopslings -X PUT \
  http://localhost:3000/api/v1/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN \
  -H 'Content-Type: application/json' -d '{"data":"<value>"}'
```

A secret can be read by any workflow in the repo, so this is a control on
*where the value is stored*, not on who can see it. That distinction matters in
hint 3.

</details>

<details>
<summary>Hint 2 — the check still fails, and the pipeline is green</summary>

Then the remaining failure is objective 3.

Ask who has the old value. Everyone who cloned the repo. Everyone who read a
build log. Whoever scraped the forge. If the repo was ever public, whoever runs
one of the bots that watch public pushes for exactly this pattern — those find
committed credentials in seconds, not days.

Deleting the line removes it from the *current* tree. It does not remove it
from any of those people.

Look at the log of the run your change triggered:

```
deploying with token=***
token fingerprint=c5bb5b4bc073
```

The forge masks a value it knows is a secret, so the first line looks identical
whether you rotated or not — masking hides the value from the log, not from
whoever already has it. The fingerprint is a hash, so there is nothing to mask,
and `c5bb5b4bc073` is the fingerprint of the token that was published.

</details>

<details>
<summary>Hint 3 — what "fixing a leak" actually means</summary>

Order matters, because the middle step is the one with an outage in it:

1. **Issue a new credential** at the provider. Do this first — you want the
   replacement in hand before the old one stops working.
2. **Store it** as a repository secret and point the workflow at it.
3. **Revoke the old one.** Until you do, the leak is live; everything before
   this step is housekeeping.
4. **Scrub and audit.** Rewrite the history if the repo is public
   (`git-filter-repo` — module 04), and read the provider's access logs to find
   out whether anyone used it while it was exposed.

Step 3 is the fix. Steps 1 and 2 exist so that step 3 doesn't take production
down with it.

</details>

<details>
<summary>Solution</summary>

Generate a new token, store it, and reference it:

```
new=dpl_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

curl -fsS -u devops:devopslings -X PUT \
  http://localhost:3000/api/v1/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN \
  -H 'Content-Type: application/json' -d "{\"data\":\"${new}\"}"
```

`.forgejo/workflows/deploy.yml`:

```yaml
name: deploy

on: [push]

jobs:
  deploy:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm run deploy
        env:
          DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

```
git commit -am "read DEPLOY_TOKEN from repository secrets" && git push
```

At a real provider there is a fifth command — revoking `dpl_9f3c…`. There is no
provider here to revoke it at, so the check settles for proving the pipeline
deploys with a value that was never published.

### Why the `env:` moved down the file

The broken version declared the token at workflow level, so it was in the
environment of every step in every job — including `actions/checkout`, and
including any step a future contributor adds. The fix scopes it to the one step
that needs it. Secrets follow the same rule as any other privilege: the smaller
the scope, the smaller the incident.

### Masking is not protection

Forgejo and GitHub both replace known secret values with `***` in log output.
That is a convenience, and it fails in every interesting case: the value gets
base64'd, or split across lines, or passed to a tool that reformats it, and the
mask no longer matches. Masking makes an accidental `echo` less bad. It is not
a reason to relax about what a job can read.

Notice also what masking cannot do here — the runs from *before* the secret
existed still hold the literal in their logs, and go on holding it after you
have fixed everything. The forge had no idea it was a secret at the time it
wrote them. Logs are append-only artefacts of a moment; classifying a value as
sensitive afterwards does not travel backwards. That is why the check grades
only the run for your commit, and why the real-world step 4 is *audit the
provider's access log*, not *find every copy*. You cannot find every copy.

And the reason `deploy.js` prints a fingerprint instead of the value: a
fingerprint tells you *which* credential a deploy used — enough to answer "did
the rotation actually reach production" — while being useless to anyone who
reads it. Log the identity of a secret, never the secret.

### The four-step drill, again

**Issue → store → revoke → scrub and audit.**

Most leak handling in the wild stops after "delete the line and force-push",
which addresses the *embarrassment* and none of the *exposure*. If you take one
sentence from this lesson: a credential that has been committed is a credential
that has been published, and the only thing that unpublishes it is revoking it.

The audit step is worth its own habit. Providers expose access logs for tokens;
after any leak, the question "was it used, from where, and for what" has an
answer, and it is the difference between an incident report that says *we
rotated it* and one that says *we rotated it, and nothing touched it in the
eleven days it was exposed*.

</details>
