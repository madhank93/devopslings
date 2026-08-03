# Expand the exercise inventory to full role and difficulty coverage

> **Status: executed.** `EXERCISES.md`, `CURRICULUM.md` and `README.md` now
> carry the expansion, and the three module directories were renamed. The
> shipped result is **274 exercises across 27 exercise-bearing modules** rather
> than the ~259 estimated below: an `intro` rung was added to every module that
> lacked one, which the estimate had not accounted for. The per-module counts in
> this document are therefore the plan's, not the outcome's — `EXERCISES.md` is
> authoritative. Everything else below was executed as written.

## Context

`EXERCISES.md` (170 entries, 20 modules) covers everything `CURRICULUM.md`
declares — but the curriculum itself was built from the roadmap.sh DevOps spine,
and that spine has role-shaped holes. Audited against nine job titles
(system administrator, network engineer, database administrator, systems
engineer, Linux admin, DevOps, platform, cloud, SRE — at architect level), the
inventory cannot claim to prepare anyone for three of them:

- **DBA**: no database module. Postgres appears only as a victim — a backup
  target in 17, an HA replica in 16. No query plans, no lock contention, no
  MVCC bloat, no replication lag, no schema migration.
- **Platform engineer**: no module. No golden path, no policy-as-code guardrail,
  no self-service environment, no ownership metadata, no adoption metric.
- **Cloud engineer**: floci is used in exactly one exercise. No IAM, no VPC/SG,
  no object-storage exposure, no cost.

Four more gaps are partial: scripting (roadmap.sh's "learn a programming
language" spine is absent entirely), storage/kernel (no LVM, fstab, cgroup CPU
throttling, `iostat`, `perf`), security hardening (no sudoers, AppArmor, auditd,
setuid), and networking below the application layer (module 02 is all DNS/TLS/
proxy — no routing table, conntrack, accept queue, pcap, netns).

Separately, **no entry carries a difficulty marker** and there is no beginner
rung: every module-01 entry is intermediate triage, so a reader who cannot yet
write a systemd unit has nowhere to start.

Eight concrete mismatches between the two files also need closing (listed under
*Reconciliation* below).

Outcome: `EXERCISES.md` and `CURRICULUM.md` describe **28 modules / ~259
exercises**, every entry tiered intro → core → deep → architect, with a
role-to-module map so a reader arriving from a job title can find their track.
Specs only — no lessons built, no sandboxes built.

---

## Difficulty tiers

Added to every entry, existing and new, in the status parens:
`- **slug** *(core · shipped)* — …`

| Tier | Definition |
|---|---|
| **intro** | One concept, guided. The goal is fluency with a tool, not diagnosis. First guess may be *absent* — rule 2 is relaxed here and only here. |
| **core** | The repo's standard shape: already broken, obvious first guess is wrong, check measures the cause. |
| **deep** | Requires measurement or a mechanism below the tool's surface — a profile, a packet capture, a kernel counter, an arithmetic argument. |
| **architect** | A written decision or design, graded against a rubric. No single right command. |

Each module header gains a tier split:
`linux-box · 18 exercises · 5 shipped · 4 intro · 9 core · 4 deep · 1 architect`

Rule 2 in "How to read an entry" gets a sentence noting the intro exemption.

---

## New module numbering

Insert in pedagogical order and renumber. Three directory renames in
`courses/devopslings/`: `module-05` → `module-09`, `module-07` → `module-12`,
`module-15` → `module-21`. `module-01` is unchanged. Lesson slugs are unique and
are what progress is keyed on, so recorded progress survives the rename.

**New modules are 02, 03, 04, 07, 10, 17, 26.**

| # | Module | Sandbox | Ex | Was |
|---|---|---|---|---|
| 01 | Linux & Terminal Triage | linux-box | 18 | 01 (+6) |
| **02** | **Scripting & Automation** | linux-box | 9 | new |
| **03** | **Storage, Filesystems & the Kernel** | linux-box (priv) | 10 | new |
| **04** | **Networking I — Packets, Interfaces & the Kernel Path** | netlab | 10 | new |
| 05 | Networking II — Protocols & Services | netlab | 11 | 02 |
| 06 | Web Servers & Proxies | web-stack | 9 | 03 |
| **07** | **Security Hardening & Access Control** | linux-box | 10 | new |
| 08 | Version Control | scratch repos | 7 | 04 |
| 09 | Containers | scratch | 11 | 05 |
| **10** | **Databases & Data Stores** | **db-stack (new)** | 14 | new |
| 11 | Artifacts & Supply Chain | ci-stack | 8 | 06 |
| 12 | CI/CD | ci-stack | 10 | 07 |
| 13 | IaC: OpenTofu | iac-stack | 10 | 08 |
| 14 | IaC: Pulumi (Go) | iac-stack | 5 | 09 |
| 15 | Config Management: Ansible | linux-box | 6 | 10 |
| 16 | Secrets | ci-stack | 6 | 11 |
| **17** | **Cloud Fundamentals & IAM** | iac-stack (floci) | 10 | new |
| 18 | Metrics | obs-stack | 10 | 12 (+2) |
| 19 | Logs & Traces | obs-stack | 8 | 13 |
| 20 | Performance, Percentiles & Scalability | obs+chaos | 14 | 14 (+3) |
| 21 | Failure Handling & Resilience | chaos-stack | 12 | 15 (+1) |
| 22 | High Availability | ha-stack | 10 | 16 (+1) |
| 23 | Backup & Disaster Recovery | ha-stack | 9 | 17 (+1) |
| 24 | SRE Practice & Progressive Delivery | ha+obs | 13 | 18 (+3) |
| 25 | DORA & Delivery Measurement | ci+obs | 6 | 19 |
| **26** | **Platform Engineering** | ci-stack + obs-stack | 9 | new |
| 27 | Capstone | all | 4 | 20 |
| 28 | Handoffs | — | — | 21 |

**Total ~259 exercises. Only one new sandbox** (`db-stack`) beyond the five
already queued — 03 reuses `linux-box` with a privileged profile (loop devices,
`SYS_ADMIN`), 07 reuses `linux-box` (AppArmor, which works under Docker on
Debian — SELinux does not, and the specs must say so), 17 reuses `iac-stack`'s
floci, 26 composes `ci-stack` and `obs-stack`.

`db-stack`: Postgres primary + replica, pgbouncer, Redis, a seeded 10M-row
table, `pg_stat_statements` enabled.

---

## New exercise specs

Each line below is `slug — the trap`. Execution expands each into the existing
four-line entry format (scenario / *First guess* / *Check* / *Source*), applying
the three rules in the file header. Tier in brackets.

### 01 additions — the beginner rung (6)
- `find-the-evidence` [intro] — which of `journalctl`, `dmesg`, `/var/log` holds the answer, and why the app's own log is empty
- `package-held-back` [intro] — `apt upgrade` silently keeps a package at the old version
- `write-a-unit` [intro] — author a unit from scratch: `Type=`, `Restart=`, `After=` vs `Requires=`
- `users-groups-sudoers` [intro] — a user in the group who still cannot; secondary group needs a new login session
- `signals-and-detach` [core] — the job dies when the SSH session drops; `nohup`/`setsid`/process groups
- `journal-eats-the-disk` [core] — journald with no `SystemMaxUse`; callback to disk-full-triage

### 02 — Scripting & Automation · linux-box · 9
- `unquoted-and-broken` [intro] — a filename with a space destroys the loop
- `exit-codes-and-pipefail` [core] — the script reports success because only the last pipe stage is checked
- `set-e-does-not-do-that` [core] — `set -e` is off inside `if`, `&&`, and command substitution; the failure passes through
- `idempotent-by-construction` [core] — a script that breaks on the second run; make re-running a no-op
- `arguments-and-usage` [intro] — flags, defaults, and failing loudly on a missing required argument
- `trap-and-cleanup` [core] — the temp directory survives every interrupt; `trap … EXIT`
- `parse-do-not-scrape` [core] — the log parser breaks when a field gains a space; the answer is `jq`, not a wider regex
- `python-for-the-api` [deep] — pagination, retry with backoff, and rate-limit headers; a naive loop misses 40% of records
- `when-bash-stops` [architect] — a rubric-graded verdict on which of four scripts should have been a program

### 03 — Storage, Filesystems & the Kernel · linux-box (priv) · 10
- `mount-and-fstab` [intro] — a typo in `fstab` and a box that will not come back
- `lvm-extend-under-pressure` [core] — grow the volume and the filesystem, in the right order, live
- `uuid-not-device-name` [core] — `/dev/sdb` moved after reboot and the wrong volume mounted
- `swap-and-swappiness` [core] — the box is slow, not out of memory; page-out rate, not free bytes
- `cgroup-cpu-throttling` [deep] — CFS quota, `nr_throttled`, and the p99 spike no CPU graph shows
- `iostat-await-versus-util` [deep] — 100% util that is not saturated, and the queue depth that is
- `page-cache-versus-rss` [deep] — "the app is leaking" is the page cache; `free`, `smaps`, `working set`
- `fsync-and-the-lie` [deep] — the write returned and the data is gone; barriers and `nobarrier` mount options
- `sysctl-that-survives` [core] — the tuning works until reboot; `/etc/sysctl.d` and where the vendor default came from
- `capacity-from-growth` [architect] — sizing a volume from a growth curve and a retention policy, graded on the arithmetic

### 04 — Networking I: Packets, Interfaces & the Kernel Path · netlab · 10
- `read-the-routing-table` [intro] — three routes, one destination; which wins and why
- `two-default-routes` [core] — asymmetric return path; replies leave by the wrong interface
- `netns-veth-bridge` [core] — build a container's network by hand, then name what Docker did
- `conntrack-table-full` [deep] — new connections fail while the box is idle; `nf_conntrack_count`
- `accept-queue-overflow` [deep] — `somaxconn`/backlog; `ss -lnt` Recv-Q and the silent SYN drops
- `read-the-capture` [deep] — a pcap; distinguish retransmit, RST, and zero-window from each other
- `nat-and-hairpin` [core] — the service is reachable from outside and not from itself
- `ipv6-preferred-and-broken` [core] — AAAA is answered, the route is not; every connection waits for the v4 fallback
- `tcp-keepalive-versus-idle-timeout` [core] — the connection is dead and both ends believe otherwise
- `l4-versus-l7` [architect] — a rubric-graded choice per scenario, including the one where L7 cannot help

### 07 — Security Hardening & Access Control · linux-box · 10
- `sudoers-that-grants-root` [core] — a "safe" NOPASSWD entry with a shell escape behind it
- `apparmor-denial` [deep] — the service works with the profile in complain and fails in enforce; read `audit.log`, do not disable the profile
- `setuid-hunt` [core] — find every setuid binary that should not be one, without breaking `ping` and `sudo`
- `ssh-hardening` [core] — key-only, no root, `authorized_keys` permissions, and the second session that proves you are not locked out
- `auditd-who-changed-it` [deep] — a file changed at 02:00; produce the who and the how from the audit trail
- `least-privilege-service` [core] — a unit running as root; `User=`, `ProtectSystem=`, `NoNewPrivileges=`, still working
- `fail2ban-and-the-false-positive` [core] — the ban rule that eventually bans the load balancer
- `patch-without-reboot-roulette` [core] — unattended-upgrades, and which updates genuinely need the reboot
- `file-integrity-baseline` [core] — a baseline that survives a legitimate deploy and still catches the planted change
- `threat-model-this-box` [architect] — rubric-graded: assets, entry points, and the control that is missing

### 10 — Databases & Data Stores · db-stack (new) · 14
- `connect-and-grant` [intro] — roles, `GRANT`, and the app user that can drop tables
- `read-the-plan` [intro] — `EXPLAIN ANALYZE` on a 10M-row seq scan; estimated vs actual rows
- `the-index-that-is-not-used` [core] — an index exists and the planner ignores it (implicit cast / function on the column)
- `index-that-costs-more-than-it-saves` [deep] — write amplification; six indexes on a write-heavy table
- `n-plus-one` [core] — the app is slow and every query is fast; `pg_stat_statements` calls, not mean time
- `lock-contention` [core] — a long transaction blocks a migration and the whole queue behind it; `pg_locks`
- `deadlock-detected` [deep] — two transactions, opposite order; the fix is ordering, not retry
- `isolation-anomaly` [deep] — read-committed lost update; `SELECT … FOR UPDATE` vs serializable, with the cost of each measured
- `bloat-and-autovacuum` [deep] — the table grew 4× with no new rows; autovacuum starved by a long-lived transaction
- `xid-wraparound-warning` [deep] — the warning nobody reads until the database refuses writes
- `replication-lag-stale-read` [core] — the write succeeded and the read does not see it; sync vs async, and read-your-writes
- `zero-downtime-migration` [deep] — `ADD COLUMN NOT NULL DEFAULT` takes the table lock; expand → backfill in batches → contract
- `redis-eviction-and-persistence` [core] — cache misses after a restart, and the `maxmemory-policy` that silently discarded the queue
- `pick-the-store` [architect] — rubric-graded: four workloads, which store and which constraint decided it

### 17 — Cloud Fundamentals & IAM · iac-stack (floci) · 10
- `identity-not-keys` [intro] — a static key pair in the repo; instance role instead
- `policy-least-privilege` [core] — `Action: "*"` narrowed until the app still works and the probe fails
- `assume-role-across-accounts` [core] — the trust policy that is open to the world
- `public-bucket` [core] — the object is public through a path nobody audited; block-public-access plus the policy
- `presigned-not-public` [core] — sharing one object without opening the bucket, with an expiry that is proven
- `sg-versus-nacl` [core] — stateful vs stateless; the return traffic that a NACL drops
- `private-subnet-egress` [core] — the instance cannot reach the internet and must not be reachable from it
- `lifecycle-and-versioning` [core] — the delete that was not a delete; recovery plus a lifecycle that bounds the cost
- `cost-surprise` [deep] — find the $2k/month: unattached volumes, egress, and the untagged resource nobody owns
- `managed-versus-self` [architect] — rubric-graded: what a managed service actually removes from your on-call

### 26 — Platform Engineering · ci-stack + obs-stack · 9
- `golden-path-template` [core] — a new service gets CI, a dashboard and an alert without asking anyone
- `paved-road-guardrail` [core] — policy-as-code rejects the misconfiguration and still permits the documented exception
- `self-service-with-a-budget` [core] — ephemeral environments that expire; the one that never gets torn down
- `ownership-metadata` [core] — a page with no owner; the catalog entry that routes it
- `platform-slo` [deep] — the platform's own SLI, and the difference between "CI is up" and "CI is useful"
- `adoption-not-mandate` [deep] — the golden path that two teams route around; find why from the data
- `noisy-neighbour` [deep] — one tenant's build starves the shared runners; quota and isolation
- `deprecate-a-paved-road` [core] — migrate every consumer off v1 with a check that proves none is left
- `platform-as-a-product` [architect] — rubric-graded roadmap from the adoption and toil data

### Additions to existing modules (12)
- **18 Metrics**: `dashboard-that-answers-a-question` [core] (the CURRICULUM promise), `exporter-you-write` [core]
- **20 Performance**: `load-test-shapes` [core] (ramp/soak/spike/stress/breakpoint — CURRICULUM promise), `k6-thresholds-as-a-gate` [core], `usl-and-the-second-coefficient` [architect]
- **21 Resilience**: `incident-aws-s3-2017` *(replay)* [architect] — cited in CURRICULUM, never specified
- **22 HA**: `incident-facebook-bgp-2021` *(replay)* [architect] — cited in CURRICULUM, never specified
- **23 DR**: `region-loss-tabletop` [architect] — CURRICULUM promise
- **24 SRE**: `incident-command` [core], `capacity-planning` [architect] (both CURRICULUM promises), `error-budget-policy` [architect]
- **01**: the six listed above

---

## Reconciliation

Eight mismatches to close while renumbering:

1. Module 02→05 sandbox: CURRICULUM says `linux-box`, EXERCISES says `netlab`. **netlab wins**; fix CURRICULUM.
2. CURRICULUM marks Containers *shipped*; 8 of 11 are unbuilt → *partly shipped*.
3. CURRICULUM lists 7 module-01 exercises against EXERCISES' 12 (soon 18) — regenerate the section.
4-8. The AWS S3 2017, Facebook BGP 2021, load-test shapes, Grafana dashboards, region-loss tabletop, incident command and capacity planning promises now have entries (above).

Add a **role → module map** to `CURRICULUM.md`, directly answering "which of
these nine job titles does this course serve, and where":

| Role | Core track |
|---|---|
| Linux / system administrator | 01, 02, 03, 07, 15 |
| Network engineer | 04, 05, 06, 22 |
| Database administrator | 10, 22, 23 |
| Systems engineer | 03, 09, 20 |
| DevOps engineer | 08, 09, 11, 12, 13, 15, 16 |
| Platform engineer | 26, 12, 13, 16, 18 |
| Cloud engineer | 17, 13, 14, 22 |
| SRE | 18, 19, 20, 21, 22, 23, 24, 25 |
| Architect (any of the above) | every `[architect]` entry, 27 |

---

## Files

- `EXERCISES.md` — the bulk. Renumber all sections, add tier tags to all 170
  existing entries, insert 7 new module sections, add ~89 new entries, update
  the counts header, the sandbox table (add `db-stack`), and the build order.
- `CURRICULUM.md` — renumber, add the 7 new module sections in the same prose
  voice, fix the 8 mismatches, add the role map, keep the originality rule and
  the "deliberately absent" table (add a row: cloud is floci-only, no second
  cloud; databases are Postgres and Redis, not five engines).
- `README.md` — the exercise count and module count appear in the prose; update.
- `courses/devopslings/` — three directory renames: `module-05`→`module-09`,
  `module-07`→`module-12`, `module-15`→`module-21`. Content unchanged; the
  `name:` field in each `0.index.md` changes to match.

## Build order (replaces the current 10 waves)

1. Finish 01 — `permissions-triage`, `blocked-on-a-pipe`, then the 6 intro additions. No new sandbox.
2. 02 Scripting — linux-box, no new sandbox, highest value per hour after 01.
3. netlab + 04, 05 — two modules on one new sandbox.
4. **db-stack + 10** — the largest role gap; unblocks nothing else, so it can run in parallel.
5. 03 + 07 — linux-box privileged profile serves both.
6. 09 additions + 08.
7. web-stack + 06.
8. 12 additions + 11.
9. obs-stack + 18, 19 — biggest build; unblocks 20, 24, 25.
10. 20 + 21.
11. iac-stack + 13, 14, 16, 15, **17**.
12. ha-stack + 22, 23.
13. 24, 25, **26**, 27.

## Verification

- `go test -short ./...` — the course loader parses every `0.index.md`; the
  three renames must not break it.
- `./bin/devopslings doctor` and the TUI lesson list — confirms the renamed
  module directories still enumerate and that recorded progress (keyed on
  lesson slug) survived.
- Recount: `awk '/^## /{m=$0} /^- \*\*/{c[m]++} END{for(x in c)print c[x],x}' EXERCISES.md`
  — the two non-module sections ("How to read an entry", "Where the ideas come
  from") contribute 8 bullets and must be subtracted; the header's per-module
  numbers must match the counts exactly, as they do today.
- Grep both files for stale module numbers: every `module-NN` and `modules NN`
  reference must point at the new numbering.
