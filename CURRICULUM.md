# Curriculum

Twenty-eight modules. Ordering follows a progression that works pedagogically —
you cannot debug a container until you can debug a process, you cannot read a
query plan until you can read a process's memory, and you cannot set an SLO
until you understand percentiles.

Modules marked **shipped** are complete and pass the contract test. The rest are
specified and being built.

Exercise-level detail — all 274 of them, each with the scenario, the wrong first
guess, the difficulty tier and what the check measures — lives in
[EXERCISES.md](EXERCISES.md). This file is the map; that one is the itinerary.

## Difficulty

Every exercise carries a tier, so a reader can enter at the right rung rather
than at exercise one.

| Tier | What it asks | Count |
|---|---|---|
| **intro** | One concept, guided. Fluency with a tool, not diagnosis. | 29 |
| **core** | Already broken, obvious first guess wrong, check measures the cause. | 154 |
| **deep** | A mechanism below the tool's surface — a profile, a capture, a kernel counter. | 60 |
| **architect** | A written decision or design, graded against a rubric. | 31 |

Modules 01–23 and 25 each open with an `intro` exercise. Modules 24, 26 and 27
do not: they are built entirely on earlier modules, and starting there is the
mistake rather than the on-ramp.

## Which role this serves

The course is one spine, but people arrive from a job title. These are the
modules that title lives in.

| Role | Core track |
|---|---|
| Linux / system administrator | 01, 02, 03, 07, 15 |
| Network engineer | 04, 05, 06, 22 |
| Database administrator | 10, 22, 23 |
| Systems engineer | 03, 09, 20 |
| DevOps engineer | 08, 09, 11, 12, 13, 15, 16 |
| Platform engineer | 26, 12, 13, 16, 18 |
| Cloud engineer | 17, 13, 14, 22 |
| Site reliability engineer | 18, 19, 20, 21, 22, 23, 24, 25 |
| Architect, from any of the above | every `architect` entry, then 27 |

---

## Foundations

### 01 — Linux & Terminal Triage · *shipped*
`linux-box`

The floor everything else stands on. Every incident eventually bottoms out in
someone reading `df`, `ps`, or a journal on a machine that is misbehaving.

Four `intro` exercises open the module, all *shipped*, for readers who have not
done this before:

- **find-the-evidence** — `invoice-sync` died and its log file is 0 bytes, which
  is a fact rather than an absence. Four places hold evidence about a dead
  process — the journal, `dmesg`, files under `/var/log`, and a live process's
  open descriptors — and knowing which answers which question is the assumption
  every later exercise here makes.
- **package-held-back** — `apt upgrade` has exited 0 nightly for three weeks and
  the CVE fix is still not installed. Exit 0 means the job finished, not that
  the outcome happened; the diagnosis was printed every night into a log nobody
  reads. State set during an incident outlives the incident.
- **write-a-unit** — a script that works when you run it, and nothing to start
  it at boot, bring it back when it exits, or keep it behind its dependency.
  `Restart=on-failure` looks like the careful choice and silently excludes clean
  exits; a retry loop reaches the same end state as `After=` and hides a real
  ordering bug.
- **users-groups-sudoers** — dana is in the group, `id dana` agrees, and dana's
  shell says permission denied. Configuration and state diverge: a process's
  group list is built at login and never revisited. Then grant one command
  through sudo rather than a shell.

Then the triage begins.

- **disk-full-triage** *(shipped)* — `/var/log/app` is at 91% and `du` can only find 12 KB.
  Space held by a process rather than a directory entry; and why killing the
  process buys you two seconds.
- **runaway-process** *(shipped)* — four processes, one is eating the box. Work the
  60-second checklist, identify it by measurement, and leave the other three
  running. The scariest number on the screen is not the cause.
- **systemd-unit-failure** *(shipped)* — `status=1/FAILURE` tells you nothing. Get the
  application's own message out of the journal, and make the fix survive a
  reboot.
- **cron-and-path** *(shipped)* — the backup script runs perfectly when you run
  it and writes nothing at 03:17. An unescaped `%` in the crontab truncates the
  command before it runs; behind that, `cron`'s `PATH` is `/usr/bin:/bin` and
  the tool is not in it. The error went to a mailbox nobody reads. Writing a
  script that survives being run by something other than you.
- **text-at-scale** *(shipped)* — three exact answers out of a 390,000-line
  access log with `awk` and `sort`. The roadmap assumes this skill everywhere
  and teaches it nowhere; graded on the answers, so a pipeline that is slow but
  right beats a clever one that is wrong. `grep -c 503` returns 202,127; the
  answer is 8,493.
- **permissions-triage** *(shipped)* — `report-writer` cannot create a file in a
  directory its own group owns. `chmod 777` clears the error and the *next* file
  is still wrong, because two separate mechanisms decide two separate things:
  the directory's setgid bit chooses the group a new file inherits, and the
  unit's `UMask=` chooses its mode. The check ignores the files already there
  and grades the one the service writes next.
- **blocked-on-a-pipe** *(shipped)* — the nightly export is nine hours in and has
  burned no CPU. It is not stuck, it is blocked: a FIFO writer whose reader
  failed at 03:00:04 with a one-character typo in its path, hours before
  anyone looked. `/proc/<pid>/wchan` names the wait in one word — and
  restarting the job, which is everyone's instinct, destroys that answer and
  blocks again in the same place.
- Then, all *shipped*: a job that dies with the SSH session, because `&`
  backgrounds within the same session and the hangup is delivered to the
  session · a healthy service whose journal fills the disk in three weeks · the
  OOM killer's record, in the three places the application could never have
  written to · `EMFILE`, where the ceiling and the leak are two separate faults ·
  `ENOSPC` with the disk empty, because inodes are the other thing a filesystem
  runs out of · a process table full of entries `kill -9` cannot touch, because
  they are already dead · and a TLS handshake that fails against a correct
  certificate, because the client and the box disagree about what day it is.

### 02 — Scripting & Automation · *partly shipped*
`linux-box`

The roadmap says "learn a programming language" and stops. This module is the
part that bites: a script that works on your machine, on your files, once, and
then runs at 03:00 against input you did not imagine.

- **unquoted-and-broken** *(shipped)* — an archive script correct for a year,
  because every filename it had seen happened to contain no character the shell
  treats as syntax. `$(ls)` is one string that gets word-split and glob-expanded
  before the loop sees it; the run that ate the quarterly report exited 0.
- **exit-codes-and-pipefail** *(shipped)* — a nightly job that exits 0 and
  writes `0 0.00`. A pipeline has as many statuses as stages and reports one,
  and `awk` succeeded at processing nothing.
- **set-e-does-not-do-that** *(shipped)* — `set -euo pipefail` is on line 2 and
  the failure went through anyway. Four constructs suspend it, and the one
  nobody sees is `local x=$(cmd)` — a plain assignment propagates the status,
  and adding `local` for hygiene is what discards it.

Then: idempotency by construction, so the second run is a no-op ·
`trap … EXIT` and the 2 GB temp directory times forty · parsing structured data
rather than widening a regex · **a Python script that quietly misses 40% of the
records** because pagination, rate limits and transient 503s all exist · and a
written verdict on which of four scripts should have been a program.

### 03 — Storage, Filesystems & the Kernel
`linux-box` (privileged profile)

Where "the disk is slow" and "we are out of memory" each turn out to be four
different things.

`fstab` and the box that stops half way through boot · extending LVM and the
filesystem in the right order, live · UUIDs, because `/dev/sdb` moved · swap and
the page-out rate, on a box with 30% memory free · `sysctl` that survives a
reboot · **cgroup CPU throttling**: p99 spikes at 40% utilisation, and
`nr_throttled` is the only thing that says so · `iostat` await versus util, and
why 100% util is not saturation · **page cache versus RSS**, with a real but
smaller leak hidden underneath · `fsync` and which layer lied about durability ·
sizing a volume from a growth curve.

### 04 — Networking I: Packets, Interfaces & the Kernel Path
`netlab`

Module 05 debugs DNS, TLS and proxies. This one is underneath that.

Reading the routing table and knowing which of three routes wins · two default
routes and an asymmetric return path · **building a container's network by hand**
with namespaces, veth pairs and a bridge, then naming what Docker did · NAT and
the hairpin that makes a service unreachable from itself · IPv6 answered but not
routed, and the five-second stall on every connection · keepalive versus the
middlebox idle timeout · **conntrack table full** on an idle box · **accept-queue
overflow**, where the server logs nothing at all · reading a capture and telling
a retransmission from a reset from a zero window · and a rubric-graded L4-versus-L7
decision.

### 05 — Networking II: Protocols & Services
`netlab`

DNS resolution failure (`resolv.conf`, search domains, ndots) · `dig` resolves
and the app does not, because `getaddrinfo` is not `dig` · service bound to the
wrong interface · nftables drop versus reject, and how the difference tells you
which rule · the MTU black hole where small requests work and large ones hang ·
expired cert, broken chain, SNI mismatch · `curl -v` through a proxy, and the
`NO_PROXY` that internal traffic needs · ephemeral port exhaustion · **key-based
SSH**: turn password auth off without locking yourself out · **SPF, DKIM and
DMARC** against a local MTA — the records are DNS, the failure is silent, and
the symptom is "our mail goes to spam" · an OSI-layered triage drill whose
seeded layer changes every run.

### 06 — Web Servers & Proxies
`web-stack`

nginx serving 403 because of a parent directory · the `proxy_pass`
trailing-slash trap · 502 vs 504, which end is broken · the load-balancer health
check that lies · stale cache serving yesterday's deploy · 413 and buffering, at
exactly 1 MB · `X-Forwarded-For` and a rate limiter that blocks everyone at once ·
WebSocket upgrade and the socket that dies at 60 seconds · Caddy automatic HTTPS ·
the Cloudflare 2019 regex postmortem.

### 07 — Security Hardening & Access Control
`linux-box`

AppArmor, not SELinux: every sandbox is Debian, and SELinux does not enforce
meaningfully inside a container. The mechanism transfers; the tool differs, and
each lesson says so.

Predicting who can read a file before running anything · **the NOPASSWD sudoers
entry with a shell escape behind it** · the setuid hunt that must not break
`ping` and `sudo` · SSH hardening with the existing session still alive at the
end · a unit dropped from root to `NoNewPrivileges` and still serving on port 80 ·
fail2ban and the day it bans the load balancer · patching without reboot
roulette · **an AppArmor denial in enforce mode**, where widening the profile to
`/** rwk` fails the check · auditd answering who changed the file at 02:14 · a
file-integrity baseline that survives a deploy · and a written threat model.

### 08 — Version Control
no sandbox

Branch, commit, merge, done properly once · `git bisect` a regression across 200
commits · rebase vs merge, where one resolution loses a fix · a secret committed
→ `git-filter-repo` **and rotate it** · `reflog` after `reset --hard` on the
wrong branch · large files and LFS · a submodule CI keeps building at the wrong
commit · and a pre-commit hook, with a written answer for what `--no-verify` does
to your plan.

### 09 — Containers · *partly shipped*
`none` (scratch workspace)

A container is a process with an unusual view of the filesystem and the network.

- **build-run-inspect** — build an image, run it, and find the file you wrote
  after the container exits. The container-is-not-a-VM moment, before anything
  is broken.
- **pid1-signals** *(shipped)* — `docker stop` takes exactly ten seconds, every
  time, and the shutdown handler never runs. What PID 1 means, and what
  shell-form `CMD` really does.
- **layer-cache-and-size** *(shipped)* — 1.16 GB image, and every commit rebuilds
  the world. Order layers by change frequency; ship only what runs.
  1158 MB → 149 MB.
- **compose-networking** *(shipped)* — the API can't reach Redis and both are
  healthy. What `localhost` means inside a container, and why publishing a port
  didn't help.
- Then: uid mismatch on a volume · the build arg still in `docker history` ·
  `.dockerignore` and 30 seconds of context · health checks that mean readiness ·
  `exec format error` on the runner · the memory limit and the heap setting that
  must agree · logs that fill the host · one capability instead of `--privileged`.

### 10 — Databases & Data Stores
`db-stack`

The gap this course had. Postgres appeared in modules 22 and 23 only as
something to fail over and restore — never as something to *operate*. An
engineer who cannot read a query plan or recognise autovacuum starvation is
carrying a pager for a system they cannot debug.

Roles and `GRANT`, so the app user cannot drop tables · `EXPLAIN ANALYZE` on
10M rows, and where the estimate went wrong · **the index that exists and the
planner ignores**, because of an implicit cast · six indexes and halved write
throughput · N+1, found by `calls` rather than by duration · lock contention
behind a session that is idle in transaction · deadlocks fixed by ordering
rather than by retrying · a lost update, and the measured cost of each way to
prevent it · **bloat and autovacuum starvation** · the XID wraparound warning
nobody reads · replication lag and read-your-writes · **a zero-downtime schema
migration** by expand, backfill in batches, contract · Redis eviction policy
silently discarding a queue that was never a cache · and a written choice of
store for four workloads.

---

## Delivery

### 11 — Artifacts & Supply Chain
`ci-stack`

Push your first image, and learn what the tag names versus what the digest
names · Harbor tag immutability, after `:latest` changed under a running
deploy · a retention policy that ate the rollback · `cosign` sign and verify ·
`syft` SBOM + `trivy` scan, with an exception that expires · pinning the base
image by digest · **dependency confusion**, where an internal name resolves to a
public package · scoped robot accounts · the left-pad and event-stream
postmortems, and why you mirror.

### 12 — CI/CD · *partly shipped*
`ci-stack`

- **run-it-on-every-push** — one workflow, one command, real exit status. The
  rung below the next one, where nothing is broken yet.
- **first-pipeline** *(shipped)* — the workflow is valid, the run was created,
  and nothing happens. `runs-on:` names a label, and a label nobody advertises
  queues forever. A job that never starts is quieter than one that fails.
- **leaked-secret** *(shipped)* — a deploy token hardcoded in the workflow.
  Remove it, source it from a secret, and **rotate** — the value was published
  the moment it was pushed, and masking only hides it from the next log.
- **green-pipeline** *(shipped)* — a month of green builds that never ran a
  test. `npm run test --if-present` against a script called `tests` exits 0 in
  silence. Make CI honest, watch it go red, and meet the bug the suite has been
  catching all along.
- Then: a cache keyed without the lockfile hash · a matrix where one shard fails
  and the report says success · promote the artefact instead of rebuilding it ·
  the branch protection with a path around it · two merges racing to deploy ·
  one Jenkinsfile lesson, because enterprises still run it · and the Cloudflare
  2019 postmortem as a staged rollout.

### 13 — IaC: OpenTofu
`iac-stack`

First resource against the docker provider · what's actually *in* state, and
state locking · drift: a resource deleted behind your back · variables, outputs,
modules · `import` an existing resource · `count` versus `for_each`, where
removing the second item destroys the third · remote backend on MinIO ·
`prevent_destroy` and blast radius · **a serverless function that times out on a
cold start** — floci emulates Lambda, so the one part of serverless worth
teaching (what "cold" costs, and why the timeout you picked is wrong) is
reachable without an AWS bill.

### 14 — IaC: Pulumi (Go)
`iac-stack`

One resource in a language with a compiler · the same infrastructure as module
13, ported · loops and conditionals HCL cannot express · stacks and config ·
**unit-testing infrastructure** with Pulumi Go mocks, so the test fails when the
bucket goes public and before anything is created · when to pick Pulumi over
OpenTofu, and when not to.

### 15 — Config Management: Ansible
`linux-box`

Inventory and ad-hoc commands · a playbook that installs and configures nginx ·
**idempotency: run it twice, assert `changed=0`** · jinja2 templates and
handlers that fire on change only · roles · a molecule test · vault and
`become` · OpenTofu provisions, Ansible configures.

### 16 — Secrets
`ci-stack`

Store a secret and read it from an application, with the value in no file, no
layer and no environment dump · OpenBao kv and per-service policy · dynamic
database credentials and leases, where revoking one kills exactly one service ·
SOPS and age encrypted files in git · a secret-sprawl audit with two secrets
that are not in obvious places · **rotation with a dual-read window and zero
failed requests** · and the module 12 token, replayed, with revocation verified
from the attacker's side.

### 17 — Cloud Fundamentals & IAM
`iac-stack` (floci)

floci emulates the AWS API locally, so identity, network and storage
misconfiguration — the three that cause the breaches — are reachable without an
account or a bill. The vocabulary is AWS-shaped because the industry's is; the
failures transfer.

Assumed roles instead of static keys · narrowing `Action: "*"` until the app
still works and a probe is denied · **the trust policy that trusts everyone**,
which is the half people forget · the public bucket, private by every route ·
presigned URLs instead of opening the bucket for an afternoon · **security
groups versus NACLs**, and the stateless rule that drops the return packet · a
private subnet with egress and no ingress · versioning, lifecycle, and the
delete that was not a delete · **finding the $2,000 nobody spent** in unattached
volumes, cross-zone egress and an untagged resource · and a written buy-or-build
verdict that must state its downside.

---

## Observability

### 18 — Metrics
`obs-stack`

Prometheus scrape and target-down · instrument an app, RED and USE · **writing
an exporter** for the thing that has none, which reports zero rather than
vanishing · Alertmanager routing, grouping and inhibition, delivering exactly
one page for a correlated outage · **a dashboard that answers three stated
questions** instead of forty panels nobody reads · a **cardinality explosion** ·
`rate` versus `increase` across a counter reset · recording rules · and the
alert that did not fire because the data stopped.

### 19 — Logs & Traces
`obs-stack`

Ship one log line and find it again · OTel Collector receivers/processors/
exporters · **OTTL** transform · **Vector + VRL**: parse, redact PII, sample,
route · Loki labels and the query that scans everything · OpenSearch index,
mapping, retention (heavy profile) · a Tempo trace that survives an async queue
boundary · correlating trace ↔ log ↔ metric with exemplars · the pipeline
silently dropping 4% of logs.

---

## Reliability

This is the part the repo exists for. Six modules, because "make it survive" is
a bigger subject than "make it run" and almost nothing teaches it hands-on.

### 20 — Performance, Percentiles & Scalability
`obs-stack` + `chaos-stack`

Compute p50, p95 and p99 by hand on 1,000 requests before querying for them ·
why the average lies, and p50 with it · Prometheus **histograms vs summaries**,
and why you cannot average a quantile across instances · **coordinated
omission**: your load generator is hiding the worst latency · **load-test shapes**
— ramp, soak, spike, stress, breakpoint — and the leak only the soak finds ·
**k6 thresholds as a gate**, with the exit code driving the pipeline · latency
budgets and fan-out amplification · **Little's Law** L = λW · the utilisation
knee, and fitting the **Universal Scalability Law** well enough to predict the
peak · connection-pool sizing with pgbouncer · cache hit ratio, TTL, and the
**stampede** · flame graphs and `pprof` · benchmarking traps: warm-up, cache
effects, noisy neighbours · why `CPU > 80%` is a bad alert.

### 21 — Failure Handling & Resilience Patterns · *partly shipped*
`chaos-stack`

The dependency is never at fault in this module. It stays up and correct; what
changes is the network to it.

- **set-a-timeout** — the one-line change, and the two timeouts it is not.
- **no-timeout-hangs** *(shipped)* — pricing gets slow, not down. Without a
  timeout, checkout's workers fill up waiting and a page that didn't need
  pricing goes down with it. Bound the wait; then notice that a fast 503 is
  still a failure.
- Then: retries **without** jitter → retry storm · exponential backoff + jitter ·
  circuit breaker open/half-open/closed · connection-pool exhaustion ·
  idempotency keys under at-least-once delivery · dead-letter queues ·
  **graceful shutdown**: SIGTERM, drain, in-flight requests · load shedding and
  backpressure · **cascading failure**: one slow dependency takes down three
  healthy services.
- **Knight Capital 2012** — a deploy to seven of eight hosts, and a flag that
  meant something else on the eighth.
- **AWS S3 2017** — a command that removed more capacity than intended, and the
  status system that depended on the thing it was reporting on. Breaking that
  circular dependency is the exercise.

### 22 — High Availability
`ha-stack`

Two nodes behind one name, as the baseline everything here breaks · hunt the
SPOF: draw the topology, then break each box · active/passive failover with
keepalived and a VIP, and the four seconds nobody measured · active/active
behind HAProxy · **the health check that lies** — 200 while the database is
down · streaming replication and promoting a replica without losing a committed
transaction · **quorum and split-brain**: three-node etcd, kill two · leader
election across a partition · graceful degradation: serve stale, not 500 ·
**GitHub 2018**, where failing back was harder than failing over · **Facebook
BGP 2021**, where the path to roll back the change was inside the thing the
change removed.

### 23 — Backup & Disaster Recovery
`ha-stack`

Take a dump, then open it and find out which table the flag excluded · define
RPO and RTO *before* designing · back up Postgres, then **restore it, verified**,
into a clean instance · PITR with WAL archiving · a **restore drill under a
timer** — measure the real RTO against the one you promised · lose the OpenTofu
state file and recover by import · lose the OpenBao unseal keys · 3-2-1,
immutable and offsite, against an attacker holding production credentials · **a
region-loss tabletop** whose every step must survive the region being gone ·
**GitLab 2017**, where all five backup methods had silently failed.

### 24 — SRE Practice & Progressive Delivery
`ha-stack` + `obs-stack`

Pick an SLI that correlates with user pain (most don't) · SLO and error-budget
maths, built on module 20's percentiles · **multi-window multi-burn-rate
alerting** · golden signals vs USE vs RED, and when each applies · identifying
and eliminating toil · **capacity planning** from the Little's Law numbers,
naming which resource saturates first · blue/green and rollback in under a
minute, with the database compatible in both directions · **canary with
automated analysis** · feature flags and a clean stale-flag audit · **incident
command**: roles held, severity called against published criteria, and a
commander who does not also debug · **an error-budget policy** with a
consequence the team can actually enforce · chaos engineering done properly:
hypothesis → blast radius → experiment → conclusion · **a blameless postmortem
for the incident you caused in module 21**.

### 25 — DORA & Delivery Measurement
`ci-stack` + `obs-stack`

Count your deploys, and say what counted · then instrument the module 12
pipeline to emit the metrics properly. Deployment frequency · lead time for
changes · change failure rate · **Failed Deployment Recovery Time** — renamed
from MTTR in 2025 and redefined to count only failures a change caused, so a
datacentre outage no longer lands in your delivery numbers · **Rework Rate**,
added in 2025, where only 7.3% of teams are under 2% · Reliability as a
quasi-metric · **the seven archetypes** that replaced Elite/High/Medium/Low ·
gaming your own metrics, and why the four keys are a guardrail rather than a
leaderboard · the AI Capabilities Model.

> The 2025 DORA report changed the model substantially. A course still teaching
> the four performance tiers in 2026 is teaching something that no longer
> exists.

---

## Platform

### 26 — Platform Engineering
`ci-stack` + `obs-stack`

The discipline the roadmap names and no exercise set teaches: making the right
thing the easy thing for teams who do not report to you, and measuring whether
they actually took it.

A golden-path template that produces a service with a pipeline, a dashboard and
an alert, all green, with no manual step · **policy-as-code guardrails** that
reject the misconfiguration and permit an exception that expires · self-service
environments with a TTL, because 40 exist and 6 are in use · ownership metadata
that routes the page, where a service with no owner fails the pipeline ·
deprecating v1 of a paved road with 30 consumers on it · **a platform SLO** that
moves when a developer cannot ship even though every component is healthy ·
**adoption, not mandate**: finding from data why two teams routed around you ·
the noisy neighbour starving a shared runner pool · and a roadmap that states
what it will say no to.

---

## Finishing

### 27 — Capstone
all stacks

Build it, break it, measure it: git push → CI → Harbor → `tofu apply` → an HA
topology → a chaos experiment → p99 holds → the SLO holds → dashboards green →
postmortem written.

### 28 — Handoffs

→ [kubelings](https://github.com/madhank93/kubelings) for Kubernetes, ArgoCD and
Istio · → [golings](https://github.com/madhank93/golings) for Go ·
→ [learn-cks](https://github.com/madhank93/learn-cks) for Kubernetes security.

---

## Where this comes from, and what is deliberately absent

The module list follows the [roadmap.sh DevOps track](https://roadmap.sh/devops)
with the open-source rule from the README applied on top. The topic list was
diffed against the live roadmap in **August 2026**. The gaps that diff exposed
are now modules rather than backlog items: scripting (02), storage and the
kernel (03), packet-level networking (04), security hardening (07), databases
(10), cloud and IAM (17), and platform engineering (26).

Not covered, on purpose:

| Absent | Why |
|---|---|
| Kubernetes, orchestration, service mesh, GitOps, sealed-secrets | Their own repos — [kubelings](https://github.com/madhank93/kubelings), [learn-cks](https://github.com/madhank93/learn-cks) |
| Datadog, New Relic, Dynatrace, Splunk, Artifactory | Proprietary. The open-source rule picks Prometheus, Grafana, Loki, Tempo, Harbor instead |
| Chef, Puppet, Salt | Ansible carries the whole configuration-management idea; three more syntaxes teach nothing extra |
| MySQL, MongoDB, Cassandra, Kafka | Module 10 is Postgres and Redis. The failures taught — plans, locks, MVCC, replication lag, eviction — are the transferable ones; a second engine repeats them in different syntax |
| The BSDs, Windows, PowerShell | Every sandbox is Debian. Breadth here costs image size and buys a skill most readers will not use |
| SELinux | Does not enforce meaningfully in a container. Module 07 teaches the same mechanism through AppArmor and says so |
| Azure, GCP | floci emulates AWS locally and free. A second cloud means a real account and a real bill |
| Docker Swarm, Consul, FTP/SFTP | Live topics on the roadmap, low value per hour in 2026 |

### Facts with a shelf life

These were verified in **August 2026** and are the ones most likely to rot.
Re-check them before quoting the numbers at anyone:

- **DORA 2025** renamed MTTR to Failed Deployment Recovery Time and redefined
  it; added Rework Rate (7.3% of teams under 2%); replaced the four performance
  tiers with seven team archetypes.
- **HashiCorp** moved Terraform and Vault to BUSL-1.1 in August 2023. OpenTofu
  (Linux Foundation, MPL-2.0) forked in September 2023; OpenBao in December 2023.
- **LocalStack** archived its GitHub repositories on 23 March 2026 and now
  requires an auth token on `latest`; the acknowledgement escape hatch expired
  on 6 April 2026. floci (MIT) is the replacement this course uses.
- **Forgejo Actions** executes GHA-compatible workflow YAML. GitHub's hosted
  service is proprietary; its runner is MIT.

### Writing a lesson: originality

Platforms like SadServers and iximiuz Labs solve the same problem this repo
does, and reading them is a good way to find out which failures are worth
teaching. **Take the idea, never the artefact.** A lesson here is written from
scratch: our own scenario text, our own service and file names, our own numbers,
our own check. Do not paste their scenario descriptions, setup scripts, task
text or solutions into this repository, and do not reproduce a scenario so
closely that it is theirs with the names changed — their material is under their
own terms, and this repo is MIT and has to stay cleanly ours. The same goes for
any blog post, course or book a lesson draws on: cite it in the walkthrough when
it earned the credit, and write the words yourself.

Cited incidents (GitLab 2017, Knight Capital 2012, AWS S3 2017, Cloudflare 2019,
Facebook BGP 2021, GitHub 2018) are a different case: link the published
postmortem, summarise it in your own words, and keep the reconstruction in the
sandbox a simplification rather than a facsimile.
