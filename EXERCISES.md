# Exercise inventory

Every exercise this course intends to ship, with enough design in each entry to
build it without re-deciding what it teaches. `CURRICULUM.md` says what a module
is *about*; this file says what you will actually be doing in it.

## How to read an entry

```
- **slug** *(status)* — the scenario, in the state the student meets it.
  *First guess:* the thing most people try, and why it does not hold.
  *Check:* what the grader measures — the thing that cannot be faked.
  *Source:* where the idea came from.
```

Three rules that shaped every entry:

1. **The check measures the cause, not the symptom.** If a student can pass by
   restarting something, the exercise is not finished.
2. **The first guess is wrong on purpose.** An exercise where the obvious move
   works teaches nothing that a man page would not.
3. **Ideas travel, artefacts do not.** Where an entry is marked *SadServers-style*
   or *iximiuz-style*, that names a family of failure that those platforms also
   teach — the scenario, names, numbers and checks here are written from scratch.
   See the originality rule at the end of `CURRICULUM.md`.

**Status**: *(shipped)* passes the contract test · *(next)* queued for the
current wave · everything else is specified and unbuilt.

**Counts**: 170 exercises across 20 modules and 9 sandboxes. 12 shipped, 2 next,
156 specified. Per module: 01/12 · 02/11 · 03/9 · 04/7 · 05/11 · 06/8 · 07/10 ·
08/10 · 09/5 · 10/6 · 11/6 · 12/8 · 13/8 · 14/11 · 15/11 · 16/9 · 17/8 · 18/10 ·
19/6 · 20/4.

---

## 01 — Linux & Terminal Triage
`linux-box` · 12 exercises · 5 shipped

- **disk-full-triage** *(shipped)* — `/var/log/app` is at 91% and `du` finds 12 KB.
  *First guess:* delete the big file — space does not come back.
  *Check:* free space holds after the deleting process is dealt with properly.
  *Source:* own; the deleted-but-open-fd family is universal.

- **runaway-process** *(shipped)* — four processes, one is eating the box.
  *First guess:* kill the one at the top of `top`.
  *Check:* the actual offender is gone and the other three still run.
  *Source:* Brendan Gregg's 60-second checklist.

- **systemd-unit-failure** *(shipped)* — `status=1/FAILURE` and nothing else.
  *First guess:* `systemctl restart`, which hits the start rate limit.
  *Check:* service active, config on disk, survives a restart, enabled.
  *Source:* own.

- **cron-and-path** *(shipped)* — the backup works by hand, writes nothing at 03:17.
  *First guess:* run it again by hand and declare it fixed.
  *Check:* real cron runs the student's crontab line and produces the backup.
  *Source:* own; `%` and `PATH` are the two classic cron bites.

- **text-at-scale** *(shipped)* — three exact answers out of a 390k-line log.
  *First guess:* `grep -c 503` — returns 202,127 against a true 8,493.
  *Check:* the three answers, recomputed from a fingerprinted log.
  *Source:* roadmap.sh gap (text processing is assumed everywhere, taught nowhere).

- **permissions-triage** *(next)* — a service cannot write to a directory it owns.
  *First guess:* `chmod 777`, which fixes it until the next file is created.
  *Check:* the service writes, new files land with the right group and mode, and
  0777 anywhere in the tree fails the check.
  *Source:* own; setgid + umask.

- **blocked-on-a-pipe** *(next)* — a job hangs forever at 0% CPU with no error.
  *First guess:* it is deadlocked in the application, so restart it.
  *Check:* the pipeline completes and the state in `/proc/<pid>/wchan` was
  correctly identified in the answer file.
  *Source:* own; writer whose reader never arrived.

- **oom-killed** — a worker vanishes nightly with no log line of its own.
  *First guess:* the app crashed; add a `try/except`.
  *Check:* the kernel's OOM record is quoted correctly and the process survives
  the same workload after the limit or the allocation is fixed.
  *Source:* SadServers-style (OOM triage is a staple).

- **too-many-open-files** — `EMFILE` under load, fine when idle.
  *First guess:* raise `ulimit -n` in your shell; the service does not inherit it.
  *Check:* the limit is raised where systemd reads it *and* the fd leak is gone —
  fd count stays flat across a second load run.
  *Source:* own.

- **inodes-not-bytes** — writes fail with `ENOSPC`, `df -h` says 40% free.
  *First guess:* look for a big file; there isn't one.
  *Check:* `df -i` usage back under threshold with the payload directory intact.
  *Source:* SadServers-style.

- **d-state-and-zombies** — a process that will not die and one that is already dead.
  *First guess:* `kill -9` both. One ignores it, the other is not a process.
  *Check:* the answer file names which is which and why, and the reaping parent
  is fixed so the zombie table stays empty under load.
  *Source:* own.

- **clock-skew** — TLS handshakes and tokens fail on one box only.
  *First guess:* the certificate is bad; regenerate it.
  *Check:* skew inside tolerance via a running time sync, not a one-shot `date`.
  *Source:* own.

---

## 02 — Networking & Protocols
`netlab` (new) · 11 exercises

- **dns-ndots-and-search** — resolution is slow and intermittently wrong.
  *First guess:* the DNS server is broken; `dig @server` works fine.
  *Check:* the app resolves in one query; `strace`-visible query count drops.
  *Source:* roadmap.sh + the Kubernetes ndots folklore, taught on plain Linux.

- **dig-works-app-doesnt** — `dig` resolves, `curl` does not.
  *First guess:* DNS. It is `nsswitch.conf` / `getaddrinfo`, not the resolver.
  *Check:* both paths resolve, and the answer file names the mechanism.
  *Source:* own.

- **bound-to-the-wrong-interface** — service healthy locally, refused from the peer.
  *First guess:* firewall. It is listening on 127.0.0.1.
  *Check:* reachable from the peer container, and still not from the world where
  the exercise says it must not be.
  *Source:* SadServers-style.

- **drop-versus-reject** — one dependency times out, another refuses instantly.
  *First guess:* both are "the firewall is blocking it" — the difference tells you
  which rule and which direction.
  *Check:* connectivity restored via the correct rule, and the answer file
  distinguishes the two signatures.
  *Source:* own.

- **mtu-blackhole** — small requests fine, large payloads hang forever.
  *First guess:* the server is slow on big bodies.
  *Check:* a 1 MB POST completes; the fix is the MTU/MSS path, not a timeout bump.
  *Source:* own; the classic overlay/VPN failure.

- **tls-chain-and-sni** — works in `curl -k`, fails in the client library.
  *First guess:* the certificate expired. The leaf is fine; the chain is not.
  *Check:* full-chain verification succeeds against the system store, and SNI
  routes to the right vhost.
  *Source:* own.

- **through-a-proxy** — half your egress works.
  *First guess:* set `HTTP_PROXY` everywhere; internal traffic then breaks.
  *Check:* external calls go through the proxy, internal ones bypass it via
  `NO_PROXY`, both verified.
  *Source:* roadmap.sh.

- **ephemeral-port-exhaustion** — a load generator starts failing to connect.
  *First guess:* the server is out of capacity; it is idle.
  *Check:* connection reuse or port-range/`TIME_WAIT` handling makes the same run
  complete cleanly.
  *Source:* own.

- **ssh-without-locking-yourself-out** — turn off password auth on a live box.
  *First guess:* edit `sshd_config`, restart, lose your session.
  *Check:* key auth works from a second container, password auth refused, and the
  existing session survived the change.
  *Source:* roadmap.sh gap.

- **spf-dkim-dmarc** — mail from the app lands in spam.
  *First guess:* the mail server is misconfigured; it is the DNS records.
  *Check:* a local MTA authenticates the message on all three, verified by the
  receiving side's headers.
  *Source:* roadmap.sh gap.

- **pattern-layered-triage** *(drill)* — one symptom, cause seeded at a random layer.
  *First guess:* start at the application, as everyone does.
  *Check:* the layer and the cause named correctly, then repaired.
  *Source:* own; OSI-ordered triage as a repeatable drill.

---

## 03 — Web Servers & Proxies
`web-stack` (new) · 9 exercises

- **trailing-slash-proxy-pass** — every path is off by one segment.
  *First guess:* rewrite rules; the answer is one character in `proxy_pass`.
  *Check:* all four upstream routes return the right body.
  *Source:* own; nginx's most reliable trap.

- **502-vs-504** — two failures that look identical in the dashboard.
  *First guess:* restart nginx. Neither is nginx.
  *Check:* each is diagnosed to the correct end (upstream dead vs upstream slow)
  and fixed differently.
  *Source:* own.

- **health-check-that-lies** — the LB keeps a broken node in rotation.
  *First guess:* increase the check interval.
  *Check:* the endpoint reflects dependency health; a broken node leaves rotation
  within the deadline, and a healthy one is never ejected.
  *Source:* Google SRE practice, ported to HAProxy/nginx.

- **stale-cache** — a deploy went out; users still see yesterday.
  *First guess:* purge the whole cache every deploy.
  *Check:* correct cache keys and `Vary` handling — new content served, and the
  cache hit ratio does not collapse.
  *Source:* own.

- **413-and-buffering** — uploads fail at exactly 1 MB.
  *First guess:* the app rejects them; the proxy does.
  *Check:* a 25 MB upload succeeds without disabling limits entirely.
  *Source:* own.

- **real-ip-and-rate-limits** — the rate limiter blocks everyone at once.
  *First guess:* raise the limit; it is counting the proxy as one client.
  *Check:* per-client limiting works with a trusted `X-Forwarded-For` chain, and
  a spoofed header cannot bypass it.
  *Source:* own.

- **websocket-upgrade** — the socket connects and dies after 60 seconds.
  *First guess:* the client reconnect logic.
  *Check:* upgrade headers and read timeouts pass a 5-minute idle socket.
  *Source:* own.

- **caddy-automatic-https** — certificates that renew themselves.
  *First guess:* copy the nginx TLS config over.
  *Check:* served over HTTPS from an ACME-issued cert (local CA), renewal path
  proven by forcing one.
  *Source:* roadmap.sh.

- **incident-cloudflare-2019** *(replay)* — one regex, global CPU exhaustion.
  *First guess:* scale out.
  *Check:* the pathological pattern is identified and bounded, and the staged
  rollout gate stops it reaching all nodes.
  *Source:* published Cloudflare postmortem, simplified.

---

## 04 — Version Control
no sandbox (scratch git repos) · 7 exercises

- **bisect-the-regression** — 200 commits, one broke checkout totals.
  *First guess:* read the diff of the suspicious-looking commit.
  *Check:* the correct commit hash, found with an automated `git bisect run`.
  *Source:* roadmap.sh.

- **rebase-or-merge** — a conflict resolved two ways, one of which loses a fix.
  *First guess:* accept theirs and move on.
  *Check:* the resulting tree contains both changes and the test suite passes.
  *Source:* own.

- **secret-in-history** — a token committed three weeks ago.
  *First guess:* `git rm` the file and push.
  *Check:* the value is absent from every reachable object *and* the answer file
  records the rotation — history rewriting alone fails the check.
  *Source:* own; pairs with module 07's leaked-secret.

- **reflog-recovery** — `reset --hard` on the wrong branch.
  *First guess:* re-clone and redo the work.
  *Check:* the lost commits are back with their original hashes.
  *Source:* own.

- **large-files-and-lfs** — the clone takes nine minutes.
  *First guess:* delete the file in a new commit; the objects stay.
  *Check:* fresh-clone size under target with the asset still available via LFS.
  *Source:* roadmap.sh.

- **submodule-detached** — CI builds an old version of a vendored library.
  *First guess:* `git pull` in the submodule.
  *Check:* the parent records the intended commit and a clean clone builds it.
  *Source:* own.

- **hooks-that-catch-it-earlier** — the same secret, stopped before the push.
  *First guess:* trust everyone to remember.
  *Check:* the hook blocks the bad commit and permits the good one, with no
  false positive on the fixture repo.
  *Source:* own.

---

## 05 — Containers
`none` (scratch workspace) · 11 exercises · 3 shipped

- **pid1-signals** *(shipped)* — `docker stop` always takes ten seconds.
  *First guess:* raise the stop timeout.
  *Check:* clean shutdown well under the grace period, handler observed running.
  *Source:* own.

- **layer-cache-and-size** *(shipped)* — 1158 MB image, every commit rebuilds.
  *First guess:* `--squash` or a smaller base alone.
  *Check:* image under 250 MB and a source-only change hits the cache.
  *Source:* own.

- **compose-networking** *(shipped)* — API cannot reach Redis, both healthy.
  *First guess:* publish more ports.
  *Check:* `/health` green via service DNS, not via published ports.
  *Source:* own.

- **uid-mismatch-on-a-volume** — the container writes as root; the host cannot read.
  *First guess:* `chmod -R 777` the volume.
  *Check:* files owned by the intended non-root uid, container still able to write.
  *Source:* own.

- **secrets-in-layers** — the build arg is in `docker history`.
  *First guess:* delete the file in a later layer.
  *Check:* the value appears in no layer of the final image; build still works.
  *Source:* own.

- **dockerignore-and-context** — a 40-second build spends 30 sending context.
  *First guess:* faster network.
  *Check:* context under target and the image still contains everything it runs.
  *Source:* own.

- **healthcheck-semantics** — the container is `unhealthy` and still serving.
  *First guess:* remove the health check.
  *Check:* the check reflects readiness, and compose `--wait` blocks correctly on it.
  *Source:* own.

- **exec-format-error** — the image runs on the laptop and not on the runner.
  *First guess:* rebuild it; same result.
  *Check:* a manifest that satisfies both architectures, verified by inspection.
  *Source:* own.

- **memory-limit-and-oom** — the container dies at exactly the same input size.
  *First guess:* the app leaks.
  *Check:* correct limit *and* correct in-container heap setting; the same input
  now completes.
  *Source:* own; pairs with 01's oom-killed.

- **logs-that-fill-the-disk** — a healthy service takes the host down in a week.
  *First guess:* delete the log file the container holds open.
  *Check:* bounded log growth under a sustained write, driver configured.
  *Source:* own; callback to disk-full-triage.

- **rootless-and-capabilities** — the container needs one privileged thing.
  *First guess:* `--privileged`.
  *Check:* the workload runs with the single capability it needs and fails a
  privilege-escalation probe.
  *Source:* roadmap.sh security basics.

---

## 06 — Artifacts & Supply Chain
`ci-stack` (Harbor) · 8 exercises

- **push-pull-and-mutable-tags** — `:latest` changed under a running deploy.
  *First guess:* re-tag and redeploy.
  *Check:* deployment pinned by digest; a re-pushed tag no longer changes what runs.
  *Source:* own.

- **retention-ate-the-rollback** — the image you need to roll back to is gone.
  *First guess:* rebuild the old commit; the build is not reproducible.
  *Check:* a retention policy that keeps what the rollback window requires, proven
  by attempting the rollback.
  *Source:* own.

- **cosign-sign-and-verify** — an unsigned image reaches staging.
  *First guess:* trust the registry.
  *Check:* signed images deploy, an unsigned or re-tagged one is rejected.
  *Source:* roadmap.sh supply chain.

- **sbom-and-the-cve-gate** — the scanner blocks the build on a CVE in a test dep.
  *First guess:* turn the gate off.
  *Check:* gate passes with a justified, expiring exception and still fails on a
  genuinely exploitable runtime CVE.
  *Source:* own.

- **base-image-by-digest** — the build broke and nothing in the repo changed.
  *First guess:* clear the cache.
  *Check:* pinned base by digest; a moved upstream tag no longer changes the build.
  *Source:* own.

- **dependency-confusion** — an internal package name resolves to a public one.
  *First guess:* rename the package.
  *Check:* the resolver prefers the internal mirror and a planted public
  impostor is never installed.
  *Source:* the left-pad and event-stream incidents, generalised.

- **registry-auth** — CI can pull, the runtime cannot.
  *First guess:* make the repository public.
  *Check:* a scoped robot account with pull-only rights, verified both ways.
  *Source:* own.

- **incident-eventstream-2018** *(replay)* — a maintainer handoff ships malware.
  *First guess:* pin versions, which this incident defeats.
  *Check:* lockfile plus mirror plus review gate stops the malicious version.
  *Source:* published write-ups, simplified.

---

## 07 — CI/CD
`ci-stack` · 10 exercises · 3 shipped

- **first-pipeline** *(shipped)* — the run is created and nothing happens.
  *First guess:* the YAML is wrong; it is valid.
  *Check:* the job actually executes on a runner that advertises the label.
  *Source:* own.

- **leaked-secret** *(shipped)* — a deploy token hardcoded in the workflow.
  *First guess:* delete the line.
  *Check:* removed from the tree, sourced from a secret, and rotated.
  *Source:* own.

- **green-pipeline** *(shipped)* — a month of green builds that ran no tests.
  *First guess:* trust the green tick.
  *Check:* CI runs the suite, goes red on the real bug, and green only once fixed.
  *Source:* own.

- **cache-poisoned-green** — CI passes with a dependency that is not in the lockfile.
  *First guess:* clear the cache manually forever.
  *Check:* cache key includes the lockfile hash; a changed lockfile misses the cache.
  *Source:* own.

- **matrix-and-fail-fast** — one shard fails, the report says success.
  *First guess:* read the summary line.
  *Check:* aggregate status reflects every shard, and a flaky shard is retried
  without hiding a real failure.
  *Source:* own.

- **promote-do-not-rebuild** — staging and production run different bytes.
  *First guess:* rebuild per environment from the same commit.
  *Check:* one artefact digest travels through every stage.
  *Source:* own.

- **branch-protection-bypass** — a change reached main without review.
  *First guess:* add a rule; the path around it is still open.
  *Check:* the bypass route is closed and the emergency path is auditable.
  *Source:* own.

- **deploy-race** — two merges deploy simultaneously and the older wins.
  *First guess:* tell people to merge slower.
  *Check:* concurrency group serialises deploys; the newest commit ends up live.
  *Source:* own.

- **jenkinsfile** — the same pipeline in the tool the enterprise actually runs.
  *First guess:* freestyle jobs and manual steps.
  *Check:* declarative pipeline reproduces build → test → publish with the same gates.
  *Source:* roadmap.sh (Jenkins is still everywhere).

- **staged-rollout** — a bad change reaches 100% of nodes in 40 seconds.
  *First guess:* faster rollback.
  *Check:* the rollout halts at the canary stage on the failing signal.
  *Source:* Cloudflare 2019, as the delivery-side lesson.

---

## 08 — IaC: OpenTofu
`iac-stack` (new) · 10 exercises

- **first-resource** — a container managed by code instead of by hand.
  *First guess:* `docker run` and write the HCL afterwards.
  *Check:* plan/apply/destroy cycle is clean and repeatable from an empty state.
  *Source:* roadmap.sh.

- **what-is-in-state** — the file everyone is afraid of.
  *First guess:* edit state by hand.
  *Check:* the resource is corrected through `state mv`/`rm`/`import`, not an editor,
  and a subsequent plan is empty.
  *Source:* own.

- **two-applies-one-lock** — a colleague applies while you do.
  *First guess:* retry until it works.
  *Check:* locking enabled and demonstrated; the second apply waits rather than
  corrupting state.
  *Source:* own.

- **drift** — someone deleted a resource in the console.
  *First guess:* re-run apply and hope.
  *Check:* drift detected in plan, reconciled, and a detection step added to CI.
  *Source:* roadmap.sh.

- **modules-and-outputs** — the same three resources copy-pasted four times.
  *First guess:* copy it a fifth time.
  *Check:* one module, four instances, no duplicated resource blocks, plan stable.
  *Source:* own.

- **import-what-exists** — infrastructure that predates the code.
  *First guess:* destroy and recreate in production.
  *Check:* imported with an empty plan afterwards.
  *Source:* own.

- **count-versus-for-each** — removing the second item destroys the third.
  *First guess:* it is a provider bug.
  *Check:* keyed addressing; removing an item touches only that item in the plan.
  *Source:* own.

- **remote-backend-on-minio** — state on a laptop.
  *First guess:* commit the state file.
  *Check:* remote backend with locking, migrated without losing resources, and the
  state file is gitignored.
  *Source:* own.

- **prevent-destroy** — a plan that would delete the database.
  *First guess:* read the plan carefully every time.
  *Check:* the destructive plan is blocked by policy, and the legitimate change
  still applies.
  *Source:* own.

- **serverless-cold-start** — a function that times out only on the first call.
  *First guess:* raise the timeout to 30 seconds.
  *Check:* cold-start latency measured, timeout justified against it, and the
  initialisation moved out of the request path.
  *Source:* roadmap.sh serverless gap, on floci.

---

## 09 — IaC: Pulumi (Go)
`iac-stack` · 5 exercises

- **same-infra-in-go** — port the module-08 stack.
  *Check:* both stacks converge on identical resources; plan is empty after port.

- **what-hcl-cannot-say** — conditional topology from a config value.
  *First guess:* nested `count` tricks in HCL.
  *Check:* the Go program produces both topologies from one input.

- **stacks-and-secrets** — dev and prod from one program.
  *Check:* per-stack config, encrypted secret never present in plaintext in the repo.

- **unit-testing-infrastructure** — a test that fails when the bucket goes public.
  *First guess:* apply and look.
  *Check:* mocks-based test fails on the bad property before anything is created.
  *Source:* Pulumi Go mocks; the capability HCL lacks.

- **when-not-to** — a decision exercise with a written verdict.
  *Check:* the answer file picks a tool per scenario and cites the constraint that
  decided it; graded against a rubric of required factors.

---

## 10 — Config Management: Ansible
`linux-box` · 6 exercises

- **inventory-and-ad-hoc** — twelve boxes, one command.
  *Check:* the fact is gathered from every host in the group, none missed.

- **the-playbook** — install and configure nginx from nothing.
  *Check:* service serving the expected page after a single run on a clean box.

- **idempotency** — the second run reports six changes.
  *First guess:* it is fine, the result is the same.
  *Check:* `changed=0` on the second run, with the same end state.
  *Source:* roadmap.sh; the property that separates config management from scripts.

- **handlers-that-never-fire** — config changes, service keeps old settings.
  *First guess:* always restart the service.
  *Check:* handler fires on change only, and the running config matches the file.

- **roles-and-molecule** — the playbook nobody can reuse.
  *Check:* role passes a molecule scenario from a clean container.

- **vault-and-become** — a password in `group_vars`.
  *Check:* encrypted at rest, decryptable in the run, absent from plaintext in git.

---

## 11 — Secrets
`ci-stack` (OpenBao) · 6 exercises

- **kv-and-least-privilege** — one token that can read everything.
  *Check:* per-service policy; the wrong path is denied and proven denied.

- **dynamic-database-credentials** — a shared password in four services.
  *First guess:* rotate it manually every quarter.
  *Check:* each service gets a leased credential; revoking a lease kills exactly
  one service's access.

- **sops-and-age** — encrypted files in git that CI can still read.
  *Check:* ciphertext in the repo, plaintext never; CI decrypts with its own key.

- **secret-sprawl-audit** — find every secret in a small estate.
  *Check:* the answer file enumerates the planted secrets, including the two that
  are not in obvious places, with no false positives.
  *Source:* own.

- **rotation-without-downtime** — rotating the credential drops requests.
  *First guess:* rotate at 3 a.m. and hope.
  *Check:* dual-read window; a rotation during load causes zero failed requests.

- **what-a-leak-costs** — the token from module 07, replayed.
  *Check:* revocation is verified from the attacker's side, not just rotated.

---

## 12 — Metrics
`obs-stack` (new) · 8 exercises

- **target-down** — a scrape target that is up but not scraped.
  *First guess:* restart Prometheus.
  *Check:* the target reports `up == 1` for the right reason (network/relabel/port).

- **instrument-red** — a service with no metrics of its own.
  *Check:* rate, errors and duration exposed and queryable, histogram buckets sane.

- **use-for-a-node** — saturation that no CPU graph shows.
  *Check:* the saturating resource is identified from utilisation/saturation/errors.

- **alert-that-pages-correctly** — an alert that fires and reaches nobody.
  *Check:* route, grouping and inhibition deliver exactly one notification for a
  correlated outage.

- **cardinality-explosion** — Prometheus memory triples after a deploy.
  *First guess:* give it more memory.
  *Check:* series count back under budget with the same question still answerable.
  *Source:* own; the most common self-inflicted observability wound.

- **rate-versus-increase** — a counter reset makes a graph lie.
  *Check:* the query survives a restart of the exporter and still reports truth.

- **recording-rules** — a dashboard that times out.
  *Check:* panel loads under the deadline; the rule's output matches the raw query.

- **absent-and-staleness** — the alert that did not fire because the data stopped.
  *First guess:* thresholds only.
  *Check:* missing data pages; a normal deploy gap does not.

---

## 13 — Logs & Traces
`obs-stack` · 8 exercises

- **collector-pipeline** — receivers, processors, exporters, in the right order.
  *Check:* a signal makes it end to end with the expected attributes.

- **ottl-transform** — one field needs to become three.
  *Check:* transformed records match the target schema; malformed input is dropped
  rather than crashing the pipeline.

- **vrl-redact-pii** — customer emails are in the logs.
  *First guess:* a regex that also eats the order ids.
  *Check:* PII gone, everything else intact, verified field by field.

- **loki-labels** — a query that scans everything.
  *First guess:* add a label for request id.
  *Check:* label cardinality bounded and the same query returns in budget.

- **mapping-explosion** — an OpenSearch index that will not accept new documents.
  *Check:* explicit mapping, bounded fields, ingest resumes without data loss.

- **broken-trace** — the trace stops at a queue boundary.
  *First guess:* the tracer is misconfigured.
  *Check:* context propagated across the async hop; one trace spans all three services.

- **exemplars** — a p99 you cannot explain.
  *Check:* the metric links to a trace that demonstrates the slow path.

- **the-four-percent** — the pipeline silently drops 4% of logs.
  *First guess:* the application stopped logging.
  *Check:* the drop is located (queue/batch/backpressure), fixed, and a metric now
  alerts on it.
  *Source:* own.

---

## 14 — Performance, Percentiles & Scalability
`obs-stack` + `chaos-stack` · 11 exercises

- **the-average-lies** — a healthy mean over a broken service.
  *Check:* the answer identifies the affected user share from the distribution.

- **histograms-versus-summaries** — averaging a quantile across instances.
  *First guess:* `avg(p99)`.
  *Check:* correct aggregate computed from histogram buckets; the wrong method's
  error is quantified in the answer.

- **coordinated-omission** — the load generator hides the worst latency.
  *First guess:* the p99 in the report is the p99.
  *Check:* open-model measurement reveals the true tail; both numbers reported.
  *Source:* Gil Tene's argument, made hands-on with k6.

- **fan-out-amplification** — a fast backend that produces a slow page.
  *Check:* the arithmetic is demonstrated and the fix (parallel/hedged/cached)
  brings the page p99 under budget.

- **littles-law** — how many workers do you actually need.
  *Check:* the computed number is validated by a run at that concurrency.

- **the-knee** — the ninth node makes it slower.
  *First guess:* scale out further.
  *Check:* the contention point is identified and throughput improves without
  adding nodes.

- **pool-sizing** — more connections, less throughput.
  *Check:* pgbouncer sized from measurement; p99 improves and errors go to zero.

- **cache-stampede** — one expiry takes the database down.
  *First guess:* longer TTL.
  *Check:* single-flight or jittered TTL; origin load stays bounded at expiry.

- **flame-graph** — 30% of CPU in a function nobody suspected.
  *Check:* the hot path is named from the profile and the fix is measured.

- **benchmark-traps** — the same code, three different numbers.
  *Check:* warm-up, cache state and noisy neighbours controlled; results repeatable
  within tolerance.

- **cpu-over-eighty** — a bad alert replaced by a good one.
  *Check:* the new alert fires on user-visible harm and stays quiet through a
  harmless CPU spike.

---

## 15 — Failure Handling & Resilience Patterns
`chaos-stack` · 11 exercises · 1 shipped

- **no-timeout-hangs** *(shipped)* — a slow dependency fills the worker pool.
  *First guess:* restart checkout.
  *Check:* bounded wait; the page that does not need pricing keeps serving.

- **retry-storm** — the retry that turns a blip into an outage.
  *First guess:* retry harder.
  *Check:* upstream request rate stays bounded during the fault window.

- **backoff-and-jitter** — synchronised retries from 200 clients.
  *Check:* request arrivals are spread; recovery time drops measurably.

- **circuit-breaker** — failing fast beats failing slowly.
  *Check:* breaker opens under sustained failure, half-opens, and closes on
  recovery — all three transitions observed.

- **pool-exhaustion** — one slow endpoint starves every other endpoint.
  *Check:* bulkheads or per-route pools keep the healthy routes serving.

- **idempotency-keys** — at-least-once delivery charges twice.
  *First guess:* deduplicate in the client.
  *Check:* replayed requests produce exactly one side effect.

- **dead-letter-queue** — one poison message stops the queue.
  *Check:* the bad message is isolated, the queue drains, and nothing is lost.

- **graceful-shutdown** — a deploy drops in-flight requests.
  *First guess:* longer grace period.
  *Check:* zero failed requests through a rolling restart under load.

- **load-shedding** — degrading on purpose beats collapsing by accident.
  *Check:* under 3× capacity, the service sheds the excess and keeps p99 for the rest.

- **cascading-failure** — one slow dependency takes down three healthy services.
  *Check:* the blast radius is contained; the unrelated services stay up.

- **incident-knight-capital-2012** *(replay)* — a deploy to seven of eight hosts,
  and a flag that meant something else on the eighth.
  *Check:* the reconstruction shows the divergence, and the fix makes a partial
  deploy detectable before it trades.
  *Source:* published SEC filing and analyses, heavily simplified.

---

## 16 — High Availability
`ha-stack` (new) · 9 exercises

- **hunt-the-spof** — draw the topology, then break each box.
  *Check:* the answer file lists every single point of failure; the grader kills
  each one and compares.

- **vip-failover** — keepalived, and the four seconds nobody measured.
  *Check:* failover completes within the stated budget with no split VIP.

- **active-active** — two nodes, one session store.
  *First guess:* sticky sessions solve it.
  *Check:* a request served by either node sees the same session; killing one
  node loses no session.

- **the-lying-health-check** *(callback)* — 200 while the database is down.
  *Check:* the node leaves rotation on dependency failure and rejoins on recovery.

- **replica-promotion** — the primary is gone; the replica is read-only.
  *Check:* promoted replica accepts writes, the application follows, and no
  committed transaction is lost.

- **split-brain** — three-node etcd, kill two.
  *First guess:* force the survivor to accept writes.
  *Check:* the cluster refuses to lose quorum, and recovery restores consistency
  without data divergence.

- **leader-election** — two schedulers both think they lead.
  *Check:* exactly one leader across a partition and a restart.

- **serve-stale** — degrade instead of 500.
  *Check:* with the backend down, users get stale-but-labelled content and the
  error budget is spent slowly rather than instantly.

- **incident-github-2018** *(replay)* — 43 seconds of partition, 24 hours of
  reconciliation.
  *Check:* the reconstruction demonstrates why failing back was harder than
  failing over; the runbook produced is graded against required steps.
  *Source:* published GitHub postmortem, simplified.

---

## 17 — Backup & Disaster Recovery
`ha-stack` · 8 exercises

- **rpo-and-rto-first** — numbers before design.
  *Check:* the stated objectives are consistent with the design that follows;
  a design that cannot meet them fails.

- **backup-then-restore** — the backup nobody has restored.
  *First guess:* the dump exited 0, so it worked.
  *Check:* a restore into a clean instance reproduces the data exactly.

- **pitr** — recover to the moment before the bad `DELETE`.
  *Check:* the target timestamp is hit; the row count matches the pre-incident state.

- **restore-under-a-timer** — measure the real RTO.
  *Check:* wall-clock restore time recorded and compared against the promise; the
  answer must reconcile the gap.

- **lost-state-file** — the OpenTofu state is gone.
  *First guess:* apply again and create everything twice.
  *Check:* infrastructure re-adopted by import; plan empty, nothing recreated.

- **lost-unseal-keys** — OpenBao sealed, keys unavailable.
  *Check:* the documented recovery path is followed, or the honest conclusion is
  reached and the rebuild is executed.

- **3-2-1-and-immutable** — the ransomware angle.
  *Check:* a backup copy survives an attacker with production credentials.

- **incident-gitlab-2017** *(replay)* — five backup methods, none working.
  *Check:* each planted failure mode is detected by a verification job the student
  writes, before it is needed.
  *Source:* published GitLab postmortem, simplified.

---

## 18 — SRE Practice & Progressive Delivery
`ha-stack` + `obs-stack` · 10 exercises

- **pick-an-sli** — three candidate indicators, one correlates with pain.
  *Check:* the chosen SLI moves during the seeded incident and stays flat during
  the seeded non-incident.

- **slo-and-error-budget** — the maths, on real numbers.
  *Check:* budget computed correctly and burn during the incident matches.

- **multi-burn-rate-alerts** — page for the fast burn, ticket for the slow one.
  *Check:* fast burn pages within minutes; slow burn does not page; a blip does
  neither.

- **golden-use-red** — the same service, three framings.
  *Check:* each framing answers the question it is good at; the mismatch is named.

- **kill-the-toil** — a weekly manual task.
  *Check:* automated, measured, and the time saved is demonstrated by a second run.

- **canary-with-analysis** — a bad build that passes CI.
  *Check:* automated analysis rejects the canary on the metric that moved.

- **blue-green-and-rollback** — roll back in under a minute.
  *Check:* traffic returns to the good version within the budget; database
  compatibility is preserved both directions.

- **feature-flag-kill-switch** — turn it off without a deploy.
  *Check:* the flag disables the path in seconds and the stale-flag audit is clean.

- **chaos-done-properly** — hypothesis, blast radius, experiment, conclusion.
  *Check:* the experiment is bounded, the hypothesis is falsifiable, and the
  written conclusion matches what the data showed.

- **the-postmortem** — for the incident you caused in module 15.
  *Check:* timeline, contributing factors, and action items with owners; graded
  against a rubric that rejects blame language and unowned actions.

---

## 19 — DORA & Delivery Measurement
`ci-stack` + `obs-stack` · 6 exercises

- **emit-the-events** — a pipeline that measures itself.
  *Check:* deployment events recorded with commit and timestamp for every deploy.

- **lead-time** — from commit to production, honestly.
  *Check:* computed distribution matches the seeded history; the median is not
  reported as the whole story.

- **change-failure-and-fdrt** — the 2025 definitions.
  *First guess:* count every incident, including the datacentre outage.
  *Check:* only change-caused failures count toward Failed Deployment Recovery
  Time; the infrastructure incident is correctly excluded.
  *Source:* DORA 2025.

- **rework-rate** — the metric most teams fail.
  *Check:* rework identified from the commit history under the published definition.

- **gaming-the-numbers** — four keys that improved while delivery got worse.
  *Check:* the gamed metric is identified and the counter-signal proposed.

- **archetypes** — where does this team actually sit.
  *Check:* the mapping is justified against the seeded data, not vibes.

---

## 20 — Capstone
all stacks · 4 stages

- **stage-1-ship-it** — commit to production through the whole pipeline.
- **stage-2-break-it** — a fault injected at a layer you are not told.
- **stage-3-hold-the-line** — p99 and the SLO survive the experiment.
- **stage-4-write-it-up** — postmortem and runbook, graded against the rubric.

Each stage's check is the composition of earlier modules' checks: nothing new is
taught, and nothing already taught may be skipped.

---

## 21 — Handoffs

Not exercises. Pointers to [kubelings](https://github.com/madhank93/kubelings),
[golings](https://github.com/madhank93/golings) and
[learn-cks](https://github.com/madhank93/learn-cks).

---

## Sandboxes this inventory requires

| Stack | State | Serves |
|---|---|---|
| `linux-box` | built | 01, 02 (partly), 10 |
| `none` (scratch) | built | 04, 05 |
| `ci-stack` | built | 06, 07, 11, 19 |
| `chaos-stack` | built | 14, 15 |
| `netlab` | **to build** | 02 — two hosts, a resolver, an MTA, controllable nftables |
| `web-stack` | **to build** | 03 — nginx, Caddy, two upstreams, a cache |
| `iac-stack` | **to build** | 08, 09 — MinIO, floci, docker provider target |
| `obs-stack` | **to build** | 12, 13, 14, 18, 19 — Prometheus, Grafana, Loki, Tempo, OTel, Vector |
| `ha-stack` | **to build** | 16, 17, 18 — HAProxy, keepalived, Postgres primary/replica, etcd |

## Build order

Each wave is a shippable slice: sandbox, then its exercises, each passing the
contract test before the next starts.

1. **Finish 01** — permissions-triage, blocked-on-a-pipe, then the four additions.
   No new sandbox; highest value per hour.
2. **netlab + 02** — the module everything else assumes and nothing teaches
   hands-on.
3. **05 additions + 04** — no new sandbox, and 04 needs only scratch repos.
4. **web-stack + 03**.
5. **07 additions + 06** — reuses `ci-stack`; supply chain rides on Harbor.
6. **obs-stack + 12, 13** — the biggest single build; unblocks 14, 18, 19.
7. **14 + 15 additions** — `chaos-stack` and `obs-stack` together; the repo's core.
8. **iac-stack + 08, 09, 11, 10**.
9. **ha-stack + 16, 17**.
10. **18, 19, 20** — practice, measurement, capstone.

## Where the ideas come from

- **[roadmap.sh DevOps](https://roadmap.sh/devops)** — the topic spine, diffed
  against the live roadmap in August 2026.
- **Published postmortems** — Cloudflare 2019, GitLab 2017, GitHub 2018, Knight
  Capital 2012, AWS S3 2017, Facebook BGP 2021, event-stream 2018. Linked and
  summarised in the student's own reading; the sandbox reconstruction is always a
  simplification, never a facsimile.
- **Brendan Gregg** — the 60-second checklist and USE, for module 01 and 12.
- **Google SRE Workbook** — SLI/SLO/error-budget and multi-burn-rate alerting
  shape module 18's checks.
- **Gil Tene on coordinated omission** — the argument module 14 makes measurable.
- **DORA 2025** — the metric definitions module 19 grades against.
- **SadServers / iximiuz Labs** — a map of which Linux and networking failures are
  worth teaching. Ideas only: every scenario, name, number and check here is
  written from scratch. See the originality rule in `CURRICULUM.md`.
