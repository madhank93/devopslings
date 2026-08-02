# Curriculum

Twenty-one modules. Ordering follows a progression that works pedagogically —
you cannot debug a container until you can debug a process, and you cannot set
an SLO until you understand percentiles.

Modules marked **shipped** are complete and pass the contract test. The rest are
specified and being built.

---

## Foundations

### 01 — Linux & Terminal Triage · *shipped*
`linux-box`

The floor everything else stands on. Every incident eventually bottoms out in
someone reading `df`, `ps`, or a journal on a machine that is misbehaving.

- **disk-full-triage** — `/var/log/app` is at 91% and `du` can only find 12 KB.
  Space held by a process rather than a directory entry; and why killing the
  process buys you two seconds.
- **runaway-process** — four processes, one is eating the box. Work the
  60-second checklist, identify it by measurement, and leave the other three
  running. The scariest number on the screen is not the cause.
- **systemd-unit-failure** — `status=1/FAILURE` tells you nothing. Get the
  application's own message out of the journal, and make the fix survive a
  reboot.

### 02 — Networking & Protocols
`linux-box`

DNS resolution failure (`resolv.conf`, search domains, ndots) · service bound
to the wrong interface · nftables silently dropping · expired cert, broken
chain, SNI mismatch · `curl -v` through a proxy · an OSI-layered triage drill.

### 03 — Web Servers & Proxies
`web-stack`

nginx `proxy_pass` trailing-slash trap · 502 vs 504, which end is broken · the
load-balancer health check that lies · Caddy automatic HTTPS · stale cache
serving old content.

### 04 — Version Control
no sandbox

`git bisect` a regression · rebase vs merge conflict · a secret committed →
`git-filter-repo` **and rotate it** · large files and LFS.

### 05 — Containers · *shipped*
`none` (scratch workspace)

A container is a process with an unusual view of the filesystem and the network.

- **pid1-signals** — `docker stop` takes exactly ten seconds, every time, and
  the shutdown handler never runs. What PID 1 means, and what shell-form `CMD`
  really does.
- **layer-cache-and-size** — 1.16 GB image, and every commit rebuilds the world.
  Order layers by change frequency; ship only what runs. 1158 MB → 149 MB.
- **compose-networking** — the API can't reach Redis and both are healthy. What
  `localhost` means inside a container, and why publishing a port didn't help.

---

## Delivery

### 06 — Artifacts & Supply Chain
`ci-stack`

Harbor push/pull and tag immutability · retention policy · `cosign` sign and
verify · `syft` SBOM + `trivy` scan · the left-pad and event-stream postmortems,
and why you mirror.

### 07 — CI/CD · *partly shipped*
`ci-stack`

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
- Cache and matrix · build → test → push → deploy · one Jenkinsfile lesson,
  because enterprises still run it · the Cloudflare 2019 regex postmortem →
  staged rollout.

### 08 — IaC: OpenTofu
`iac-stack`

First resource against the docker provider · what's actually *in* state, and
state locking · drift: a resource deleted behind your back · variables, outputs,
modules · `import` an existing resource · remote backend on MinIO · AWS-shaped
HCL against floci · `prevent_destroy` and blast radius.

### 09 — IaC: Pulumi (Go)
`iac-stack`

The same infrastructure in Go: loops and conditionals HCL cannot express ·
stacks and config · **unit-testing infrastructure** with Pulumi Go mocks · when
to pick Pulumi over OpenTofu, and when not to.

### 10 — Config Management: Ansible
`linux-box`

Inventory and ad-hoc commands · a playbook that installs and configures nginx ·
**idempotency: run it twice, assert `changed=0`** · jinja2 templates and
handlers · roles · a molecule test · OpenTofu provisions, Ansible configures.

### 11 — Secrets
`ci-stack`

OpenBao kv, dynamic database credentials, leases · SOPS and age encrypted files
in git · a secret-sprawl audit · the GitLab 2017 postmortem, where all five
backup methods had silently failed.

---

## Observability

### 12 — Metrics
`obs-stack`

Prometheus scrape and target-down · instrument an app, RED and USE · Grafana
dashboards and variables · alert rules and Alertmanager routing · a
**cardinality explosion** · recording rules.

### 13 — Logs & Traces
`obs-stack`

OTel Collector receivers/processors/exporters · **OTTL** transform · **Vector +
VRL**: parse, redact PII, sample, route · Loki and LogQL · OpenSearch index,
mapping, retention (heavy profile) · a Tempo trace across three services ·
correlating trace ↔ log ↔ metric with exemplars · the pipeline silently
dropping 4% of logs.

---

## Reliability

This is the part the repo exists for. Six modules, because "make it survive" is
a bigger subject than "make it run" and almost nothing teaches it hands-on.

### 14 — Performance, Percentiles & Scalability
`obs-stack` + `chaos-stack`

Why the average lies, and p50 with it · p95 / p99 / p99.9 and who lives in the
tail · Prometheus **histograms vs summaries**, and why you cannot average a
quantile across instances · **coordinated omission**: your load generator is
hiding the worst latency · latency budgets and fan-out amplification — a backend
p99 becomes the user's p50 at 100× fan-out · **Little's Law** L = λW · the
utilisation knee and the Universal Scalability Law, and why the ninth node makes
things slower · load-test shapes: ramp, soak, spike, stress, breakpoint · k6
thresholds as a gate · benchmarking traps: warm-up, cache effects, noisy
neighbours · flame graphs and `pprof` · connection-pool sizing with pgbouncer ·
cache hit ratio, TTL, and the **stampede** · why `CPU > 80%` is a bad alert.

### 15 — Failure Handling & Resilience Patterns · *partly shipped*
`chaos-stack`

The dependency is never at fault in this module. It stays up and correct; what
changes is the network to it.

- **no-timeout-hangs** *(shipped)* — pricing gets slow, not down. Without a
  timeout, checkout's workers fill up waiting and a page that didn't need
  pricing goes down with it. Bound the wait; then notice that a fast 503 is
  still a failure.
- Retries **without** jitter → retry storm · exponential backoff + jitter ·
  circuit breaker open/half-open/closed · connection-pool exhaustion · idempotency
  keys under at-least-once delivery · dead-letter queues · **graceful shutdown**:
  SIGTERM, drain, in-flight requests · load shedding and backpressure ·
  **cascading failure**: one slow dependency takes down three healthy services ·
  Knight Capital 2012 and AWS S3 2017.

### 16 — High Availability
`ha-stack`

Hunt the SPOF: draw the topology, then break each box · active/passive failover
with keepalived and a VIP · active/active behind HAProxy · **the health check
that lies** — 200 while the database is down · stateless vs stateful, and why HA
Postgres is hard · streaming replication and promoting a replica · **quorum and
split-brain**: three-node etcd, kill two · leader election · session affinity vs
shared state · graceful degradation: serve stale, not 500 · Facebook BGP 2021
and GitHub 2018.

### 17 — Backup & Disaster Recovery
`ha-stack`

Define RPO and RTO *before* designing · back up Postgres, then **restore it,
verified** · **GitLab 2017**, where all five backup methods failed at once ·
PITR with WAL archiving · a **restore drill under a timer** — measure the real
RTO against the one you promised · lose the OpenTofu state file and recover ·
lose the OpenBao unseal keys · 3-2-1, immutable and offsite, the ransomware
angle · a region-loss tabletop → write the runbook.

### 18 — SRE Practice & Progressive Delivery
`ha-stack` + `obs-stack`

Pick an SLI that correlates with user pain (most don't) · SLO and error-budget
maths, built on module 14's percentiles · **multi-window multi-burn-rate
alerting** · golden signals vs USE vs RED, and when each applies · identifying
and eliminating toil · capacity planning from the Little's Law numbers ·
blue/green · **canary with automated analysis** · feature flags · rollback vs
roll-forward · chaos engineering done properly: hypothesis → blast radius →
experiment → conclusion · incident command, severity, comms · **a blameless
postmortem for the incident you caused in module 15**.

### 19 — DORA & Delivery Measurement
`ci-stack` + `obs-stack`

Instrument the module 07 pipeline to actually emit the metrics. Deployment
frequency · lead time for changes · change failure rate · **Failed Deployment
Recovery Time** — renamed from MTTR in 2025 and moved from stability to
throughput · **Rework Rate**, added in 2025, where only 7.3% of teams are under
2% · Reliability as a quasi-metric · **the seven archetypes** that replaced
Elite/High/Medium/Low · gaming your own metrics, and why the four keys are a
guardrail rather than a leaderboard · the AI Capabilities Model.

> The 2025 DORA report changed the model substantially. A course still teaching
> the four performance tiers in 2026 is teaching something that no longer
> exists.

---

## Finishing

### 20 — Capstone
all stacks

Build it, break it, measure it: git push → CI → Harbor → `tofu apply` → an HA
topology → a chaos experiment → p99 holds → the SLO holds → dashboards green →
postmortem written.

### 21 — Handoffs

→ [kubelings](https://github.com/madhank93/kubelings) for Kubernetes, ArgoCD and
Istio · → [golings](https://github.com/madhank93/golings) for Go ·
→ [learn-cks](https://github.com/madhank93/learn-cks) for Kubernetes security.
