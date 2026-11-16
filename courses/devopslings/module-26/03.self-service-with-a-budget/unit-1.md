---
title: "Forty preview environments, six in use"
---

## The situation

`devops/environments` is the registry of preview environments: one JSON file
per environment under `envs/`, and a provisioner that brings up whatever is
there and tears down whatever is removed. A developer makes one with
**Actions → create → Run workflow**, no ticket, which is the part that works.

The part that does not is the other end. `COST.md`:

```
40 environments × €11.40/day. Traffic in the last 7 days: 6 of them.
```

Thirty-four environments are from last month. Nothing removes one, and the
README's answer is "post in #platform and we will remove it". Nobody posts.

`platform.json` already states the platform's limits:

```json
{ "ttl_hours": 72, "max_extension_hours": 168 }
```

Nothing reads it.

## Your objectives

1. An environment lives `ttl_hours` from creation, and is then removed
   without anyone asking. That includes the thirty-four already past it.
2. A developer can keep one longer by giving a reason. No ticket, no platform
   team, no admin. One extension is at most `max_extension_hours`, and the
   reason is recorded in the environment's file.
3. Creating one stays self-service.

## Getting the repo

```
git clone http://devops:devopslings@localhost:3000/devops/environments.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. `ana` / `ana-devopslings` is a developer with write access to
the repository and nothing else; the check acts as her. The runner's job image
is `node:22-bookworm`, and a workflow can push to its own repository with
`${{ secrets.GITHUB_TOKEN }}`, as `create.yml` already does.

## What you're being graded on

- No environment in `envs/` was created more than 72 hours ago unless it was
  extended, and the six created in the last day are still there.
- As `ana`, the check runs `create` and the new environment has an `expires`
  time 72 hours after its `created` time.
- As `ana`, it runs `extend.yml` with the inputs `name`, `hours` and `reason`:
  with an empty reason the expiry does not move; with a reason and 48 hours it
  moves by 48 hours and the file records the reason; with 500 hours it moves
  by no more than 168.
- It pushes an environment that expired yesterday, and within four minutes a
  workflow run on a **schedule** has removed it, without removing the one that
  is still live.

Its probe environments are removed afterwards.

<details>
<summary>Hint 1 — the expiry belongs in the file</summary>

An `expires` field, written by `create`, is what makes the TTL a fact about
each environment rather than a rule somebody has to remember. The reaper and
the extension both work on that one field. Environments created before the
field existed can be given `created` plus the TTL.

</details>

<details>
<summary>Hint 2 — removal that nobody runs</summary>

Forgejo runs a workflow on `on: schedule` with a cron expression, from the
default branch. Every minute (`* * * * *`) is fine for a lab; production would
run hourly. A workflow that removes files pushes a commit, and so do `create`
and `extend`, so two of them can race for main: rebase and retry the push.

</details>

<details>
<summary>Hint 3 — an extension the platform team never sees</summary>

A `workflow_dispatch` with `inputs:` is a form anyone with write access can
fill in. Validate inside the job: refuse an empty reason, refuse more hours
than `max_extension_hours`, and add the reason to the environment's file, so
the history of who kept what, and why, is in git.

</details>

<details>
<summary>Solution</summary>

One script, `ci/envs.js`, with three commands, and three workflows that run it
and push the result.

```js
const { ttl_hours, max_extension_hours } = JSON.parse(fs.readFileSync("platform.json", "utf8"));
const expiry = (e) => Date.parse(e.expires || "") || Date.parse(e.created) + ttl_hours * 3600e3;

// create: expires = created + ttl_hours
// extend: refuse an empty reason or hours outside 1..max_extension_hours, then
//         expires = expiry(env) + hours, and append {by, at, hours, reason}
//         to env.extensions
// reap:   delete every envs/*.json whose expiry(env) <= now
```

`.forgejo/workflows/reap.yml`:

```yaml
on:
  schedule:
    - cron: "* * * * *"
  workflow_dispatch:
```

Each job clones with `GITHUB_TOKEN`, runs `node ci/envs.js <command>`, commits
`envs/` with `[skip ci]`, and pushes with a pull-rebase-retry loop. Run `reap`
once by hand and the thirty-four go.

### Why "please clean up" produces forty

Removing an environment is work for the person who least needs to do it: the
demo is over, the PR is merged, and the cost lands on someone else's budget.
Any process that depends on that person acting will leak at the rate people
forget. A TTL turns the default around: keeping costs a sentence, forgetting
costs nothing.

### Why the extension needs a reason and nothing else

If keeping an environment needs a ticket, people work around the TTL: they
recreate the environment each morning, or script the extension. A reason is
the smallest cost that is still a decision, and it leaves a record. When the
same environment has been extended six times for "demo", that is a
conversation worth having, and the data to have it is in git. The cap on one
extension means a forgotten environment still dies within a week.

### What a budget would add

The TTL bounds the lifetime of each environment. It does not bound how many
there are. A per-team cap enforced in `create` (refuse the eleventh) is the
other half of a budget, and the place to show each team what its environments
cost.

</details>
