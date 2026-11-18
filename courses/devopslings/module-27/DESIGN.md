# Module 27 — Capstone design

One service, `devops/checkout`, followed through four stages. Each stage's
check is built from checks earlier lessons already grade; nothing is taught
here for the first time.

## Spanning stacks

A lesson names one `sandbox.stack`; capstone stages add `sandbox.with`, the
other stacks they drive from host tasks. The runner starts `with` stacks first
and tears all of them down on reset and in the contract; tasks and shells still
target `stack`. Stacks are reached by published port (ci-stack: 3000, 5000)
or fixed container name (`devopslings-ha-ops`, `devopslings-ci-stack-db-1`).

The pipeline crosses stacks through the host daemon: CI jobs mount the socket,
so tofu's docker provider in a deploy job creates the replicas on ha-stack's
`front` network. The deploy job runs ha-stack's ops image (tofu, the docker
provider, git, curl); tofu state lives in ci-stack's Postgres (`backend "pg"`),
reachable from jobs as `db`. "Harbor" in the spec is ci-stack's `registry:2`.

## Carrying state between stages

Every stage must pass its contract from a clean sandbox, so no stage can
depend on the student having finished the last one. Stage N's init runs stage
N-1's verify; if it passes, the student's own work is kept, otherwise the
reference solution is laid down and given a pipeline run. To make that
possible, stage 1's seed and solve move into `module-27/files/` when stage 2
is built, and every stage calls them from there.

## Stages

| Stage | Stacks | Reuses the checks of |
|---|---|---|
| 1 ship-it (core) | ha-stack + ci-stack | 12/01 run-it-on-every-push, 11/01 push-your-first-image, 11/02 push-pull-and-mutable-tags, 12/07 promote-do-not-rebuild, 13/01 first-resource, 13/02 what-is-in-state, 13/07 count-versus-for-each, 13/08 remote-backend-on-minio, 22/01 two-nodes-one-name |
| 2 break-it (deep) | ha-stack + ci-stack | one of: 22/05 the-lying-health-check, 13/04 drift, 11/03 retention-ate-the-rollback, 12/05 cache-poisoned-green, 22/07 split-brain; then all of stage 1 |
| 3 hold-the-line (deep) | ha-stack + ci-stack + obs-stack | 24/02 slo-and-error-budget, 24/07 blue-green-and-rollback, 24/12 chaos-done-properly, 21/09 graceful-shutdown, 18/01 target-down; then all of stage 1 |
| 4 write-it-up (architect) | ha-stack | 24/13 the-postmortem, 24/09 incident-command |

**Stage 1.** Built. Seed: build pushes `:latest`, `deploy/main.tf` has one
replica and has never been applied. Verify runs one release check on the tip
of main (green run; commit-named tag; ≥2 containers in the shared state, by
digest, running CI's image; both servers UP on lb1 and lb2), kills a replica
under traffic, then pushes a grader commit and runs the release check again
plus the new version through `www`.

**Stage 2.** Built, as a randomised drill in the shape of 21/14. Init keeps
the student's stage 1 if its check passes (and no earlier draw is still in
the repository), else lays the reference down and ships it; then it seeds one
fault and writes what was seen to `scratch/stage-2-break-it/INCIDENT.txt`:

| Fault | Seeded as | The fault's own check |
|---|---|---|
| health (22/05) | `src/server.js` calls a pricing service; `/health` does not | pricing drops shop1: out of rotation on both LBs, no failed orders, back when healed |
| drift (13/04) | a replica removed by hand | state matches what runs; `ci/drift-check.sh` exits 0 / 2 / other, never repairs, runs on a schedule |
| retention (11/03) | a retention workflow keeping one release | after 12 stale tags and a release: the previous image still pulls, at most ten tags |
| cache (12/05) | a BuildKit cache mount that returns the first build's bundle | cache mount kept; stage 1's probe reaches www |
| split (22/07) | the on-call's `hotfix` workspace owns the replicas, with `PAYMENTS=disabled` | one state manages production, and the flag survives |

`inject_fault` only resets the pricing service; nothing else needs arming.
The verify runs the fault's check, then all of stage 1, then the fault's
check again for health, cache and split, on what the pipeline redeployed: a
repair made to running containers passes the first and fails the last.
`run_jobs` waits for the newest run of every workflow on a commit, since the
retention and drift workflows run beside `ci.yml`.

**Stage 3.** k6 at a constant arrival rate on the `front` network against
`www` while the grader (a) pushes a release and (b) kills a replica. Pass is
p99 and the error budget held over the window, measured from HAProxy's own
metrics, which obs-stack's Prometheus scrapes once init connects it to
`front`. The seed's in-place replace (destroy then create both) breaks the
SLO; the fix is the earlier lessons' rolling or blue-green deploy plus a
drain on SIGTERM.

**Stage 4.** No new system work. `scratch/stage-4-write-it-up/` holds
`postmortem.md` and `runbook.md`; the check is 24/13's rubric (timeline,
impact in SLO terms, contributing factors not blame, owned action items),
with the timeline checked against the times stages 2 and 3 recorded, and
every runbook command run against the sandbox.

## Known limits

- `devopslings stop` and the UI's shared-sandbox warning only look at
  `stack`, not `with`.
- The replicas are not compose containers, so tearing ha-stack down leaves
  them holding `front`; compose reuses the network on the next start and
  stage 1's init removes them.
- Stage 2's drift check is run by the grader in the ops image on
  `devopslings-ci-net`, as `bash ci/drift-check.sh` from the repository root.
  A `-refresh-only` plan does not work there: the docker provider reports its
  own attribute normalisation as drift on every refresh.
- Stage 1 cannot tell "plan -out then apply the file" from a bare
  `apply -auto-approve`; both leave the same state. The digest rule is what
  makes the plan meaningful, and that is graded.
