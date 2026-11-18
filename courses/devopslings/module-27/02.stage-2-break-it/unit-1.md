---
title: "Break it: a fault nobody names"
---

## The situation

checkout is in production, put there by the pipeline from stage 1. If your
stage 1 passes, it is your pipeline and your `deploy/main.tf`. If it does not,
the scenario lays stage 1's reference solution down first and ships it.

Then something goes wrong. One fault is drawn at random from five and seeded
somewhere on the path from a commit to `www`. The scenario tells you what
people saw, in `scratch/stage-2-break-it/INCIDENT.txt`, and nothing about where
the fault is. Start the lesson again and you may get a different one.

Everything you have from stage 1 is still there:

```console
$ docker exec devopslings-ha-ops curl -s http://www/
$ docker exec devopslings-ha-ops curl -s 'http://lb1:8404/stats;csv' | cut -d, -f1,2,18
$ git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

The pipeline's runs are at <http://localhost:3000/devops/checkout/actions>, the
registry at <http://localhost:5000/v2/checkout/tags/list>, and the state in
ci-stack's Postgres:

```console
$ docker exec devopslings-ci-stack-db-1 psql -U postgres -d app \
    -c 'select name from terraform_remote_state.states'
```

## Your objectives

1. Find the fault from what the incident notes describe, without being told
   which layer it is in.
2. Fix its cause, through a commit wherever the cause lives in the
   repository. A repair made by hand to a running container, a load balancer
   or the registry lasts until the next deploy.
3. Make sure the same fault cannot come back without somebody noticing, or
   without the system handling it by itself.

## What you're being graded on

Before every check, the parts of the environment the fault is replayed in go
back to their starting point. Then the check runs the module lesson's own test
for the fault that was drawn: the one from module 22, 13, 11 or 12 whose
incident this is. After that it runs all of stage 1: the release check on the
tip of `main`, a replica killed under traffic, and a grader commit taken from
`git push` to `www`. For a fault that a hand repair would hide, the fault's
own test runs once more on what the pipeline redeployed.

Each "not yet" says what the grader saw. It does not say where to look until
you have changed something.

<details>
<summary>Hint 1: reading the notes</summary>

Each incident has one place its evidence points to first:

- Errors that come and go while every server is `UP`: compare what the load
  balancer asks with what a request needs.
- A replica missing while the last pipeline run is green: compare the state
  with what is running.
- A rollback that the registry refuses: something deleted the image, and the
  registry does not delete by itself.
- A green pipeline serving old code: compare what the commit holds with what
  the image runs, `docker exec capstone-shop-1 cat /app/server.js`.
- Every push failing at deploy since an incident: read what the deploy job
  says, then what the state table holds.

</details>

<details>
<summary>Hint 2: the module each one comes from</summary>

- 22/05, the lying health check: a check has to fail when the replica cannot
  do its job, and pass again when it can.
- 13/04, drift: put production back the way the code says, and add a check
  that finds the next drift on a schedule, exits 0, 2 or an error, and never
  repairs anything.
- 11/03, retention ate the rollback: keep cleaning up, but never delete what a
  rollback needs.
- 12/05, the cache-poisoned green: keep the cache, and make what it returns
  follow its inputs.
- 22/07, split brain: one authority again, with every change somebody was told
  had been made.

</details>

<details>
<summary>Solution</summary>

**The lying health check.** `src/server.js` asks pricing for every order, and
`/health` answers `{"ok":true}` without asking. When pricing drops one
replica, half of all orders fail, and HAProxy keeps sending them there. Make
`/health` ask the same question an order asks:

```js
if (req.url === "/health") {
  price((err) => {
    res.statusCode = err ? 503 : 200;
    res.end(JSON.stringify({ ok: !err }));
  });
  return;
}
```

**Drift.** A replica was removed by hand. Any push makes the pipeline put it
back. Then the detector, `ci/drift-check.sh`, plans what deploying `main`
would do. It has to plan with the digest `main` deploys, because a
`-refresh-only` plan reports the docker provider's own normalisation as
changes:

```sh
#!/bin/sh
cd "$(dirname "$0")/.." || exit 1
digest=$(curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://registry:5000/v2/checkout/manifests/$(git rev-parse HEAD)" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
[ -n "$digest" ] || exit 1
cd deploy || exit 1
tofu init -input=false >/dev/null || exit 1
exec tofu plan -input=false -lock=false -detailed-exitcode \
  -var "image=127.0.0.1:5000/checkout@${digest}"
```

It runs on `on: schedule:` with a cron line, in the same container image the
deploy job uses.

**Retention.** `.forgejo/workflows/retention.yml` keeps the images of the
newest `KEEP` commits on `main` and deletes every other one. With `KEEP: 1`,
each release deletes the image before it, which is the rollback target.
`KEEP: 5` keeps a rollback window and still deletes everything that is not on
`main`.

**The poisoned cache.** The Dockerfile keeps the bundled `server.js` in a
BuildKit cache mount and reuses it whenever it exists, so every build after
the first ships the first build's code. Key the cached file on the source:

```dockerfile
RUN --mount=type=cache,target=/var/cache/bundle \
    key=$(cat src/*.js | sha256sum | cut -c1-16) \
 && if [ ! -f "/var/cache/bundle/${key}.js" ]; then \
      node --check src/server.js && cp src/server.js "/var/cache/bundle/${key}.js"; \
    fi \
 && cp "/var/cache/bundle/${key}.js" /app/server.js
```

**Split brain.** The on-call deployed from a second workspace, `hotfix`. The
pipeline's `default` state still lists containers that are gone, so every
apply tries to create replicas whose names and addresses the hotfix already
holds. Move ownership back to one state: `tofu state rm` the vanished
containers from `default`, `tofu import` the running ones, `tofu state rm`
them from `hotfix`, and `tofu workspace delete hotfix`. Run all of it in the
ops image on `devopslings-ci-net`. Then put `env = ["PAYMENTS=disabled"]` in
`deploy/main.tf`, because the flag was only ever on the containers.

### The part worth remembering

**The symptom is rarely where the fault is.** Each of these shows up as
"checkout is broken", in production. The causes are in a health check, a
state file, a cleanup job, a Dockerfile and a workspace. Working back from
the evidence, one layer at a time, is the skill this stage practises.

**A repair by hand is undone by the next deploy.** Each fault here has a
quick fix that makes the symptom go away: restart the replica, re-push the
image, clear the cache, delete the containers. The grader ships a commit
after your fix for exactly that reason.

</details>
