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
- **cron-and-path** — the backup script runs perfectly when you run it and
  writes nothing at 03:00. `cron` gives you a different `PATH`, no TTY and a
  different shell, and the error went to a mailbox nobody reads. Writing a
  script that survives being run by something other than you.
- **text-at-scale** — pull one number out of a million-line log with `awk`,
  `sed` and `sort`. The roadmap assumes this skill everywhere and teaches it
  nowhere; graded on the answer, so a pipeline that is slow but right beats a
  clever one that is wrong.
- **permissions-triage** — a service cannot write to a directory it owns.
  Ownership, the sticky bit, setgid, and the umask that made the files wrong on
  creation.
- **blocked-on-a-pipe** — a job that hangs forever with no CPU and no error. A
  writer whose reader never arrived, found with `lsof` and `/proc/<pid>/wchan`.

### 02 — Networking & Protocols
`linux-box`

DNS resolution failure (`resolv.conf`, search domains, ndots) · service bound
to the wrong interface · nftables silently dropping · expired cert, broken
chain, SNI mismatch · `curl -v` through a proxy · an OSI-layered triage drill ·
**key-based SSH**: turn password auth off without locking yourself out, and
know what `authorized_keys` permissions have to be · **SPF, DKIM and DMARC**
against a local MTA — the records are DNS, the failure is silent, and the
symptom is "our mail goes to spam".

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
HCL against floci · `prevent_destroy` and blast radius · **a serverless
function that times out on a cold start** — floci emulates Lambda, so the one
part of serverless worth teaching (what "cold" costs, and why the timeout you
picked is wrong) is reachable without an AWS bill.

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
Recovery Time** — renamed from MTTR in 2025 and redefined to count only
failures a change caused, so a datacentre outage no longer lands in your
delivery numbers · **Rework Rate**, added in 2025, where only 7.3% of teams are
under 2% · Reliability as a quasi-metric · **the seven archetypes** that
replaced Elite/High/Medium/Low · gaming your own metrics, and why the four keys
are a guardrail rather than a leaderboard · the AI Capabilities Model.

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

---

## Where this comes from, and what is deliberately absent

The module list follows the [roadmap.sh DevOps track](https://roadmap.sh/devops)
with the open-source rule from the README applied on top. The topic list was
diffed against the live roadmap in **August 2026**; the gaps that diff exposed —
scripting, text manipulation, SSH, mail records, serverless — are now folded
into modules 01, 02 and 08 rather than sitting in a backlog nobody reads.

Not covered, on purpose:

| Absent | Why |
|---|---|
| Kubernetes, orchestration, service mesh, GitOps, sealed-secrets | Their own repos — [kubelings](https://github.com/madhank93/kubelings), [learn-cks](https://github.com/madhank93/learn-cks) |
| Datadog, New Relic, Dynatrace, Splunk, Artifactory | Proprietary. The open-source rule picks Prometheus, Grafana, Loki, Tempo, Harbor instead |
| Chef, Puppet, Salt | Ansible carries the whole configuration-management idea; three more syntaxes teach nothing extra |
| The BSDs, Windows, PowerShell | Every sandbox is Debian. Breadth here costs image size and buys a skill most readers will not use |
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
