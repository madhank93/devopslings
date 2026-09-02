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

### 02 — Scripting & Automation · *shipped*
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

### 03 — Storage, Filesystems & the Kernel · *shipped*
`linux-box` (privileged profile)

Where "the disk is slow" and "we are out of memory" each turn out to be four
different things.

`fstab` and the box that stops half way through boot · extending LVM and the
filesystem in the right order, live · UUIDs, because `/dev/sdb` moved · **swap
and the page-in rate**: a batch job nine times slower on a box with gigabytes
free, because the limit it hit was the unit's and not the machine's · `sysctl`
that survives a reboot · **cgroup CPU throttling**: p99 spikes at 40%
utilisation, and `nr_throttled` is the only thing that says so · **`iostat`
await versus util**: the busy volume is fine and the quiet one is the outage ·
**page cache versus RSS**, with a real but smaller leak hidden underneath ·
**`fsync` and the lie**: the write returned committed, exited 0, and the record
is gone · sizing a volume from a growth curve, where the average is the one
window it will never have to hold.

### 04 — Networking I: Packets, Interfaces & the Kernel Path · *shipped*
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

### 05 — Networking II: Protocols & Services · *partly shipped*
`netlab`

- **resolve-connect-request** *(shipped)* — three tickets, all of them saying
  "connection failed", broken at three different steps. The decomposition the
  rest of the module is built on: resolve, connect, request, one tool each.
- **dns-ndots-and-search** *(shipped)* — the resolver is healthy, `dig` is
  correct, and the application reaches another team's host. `ndots:5` and a
  wildcard in the first search domain.
- **dig-works-app-doesnt** *(shipped)* — the name resolves for you and not for
  the service on the same box. `getaddrinfo` reads `nsswitch.conf` first, and
  `dig` never does.
- **bound-to-the-wrong-interface** *(shipped)* — healthy locally, refused from
  everywhere else, with a firewall present and innocent. `0.0.0.0` is not the
  fix: the box faces two networks and the service belongs on one.
- **drop-versus-reject** *(shipped)* — six seconds against fifteen milliseconds,
  same firewall, two verdicts. Time-to-failure names the rule before you read
  one, and flushing the ruleset takes a deliberate quarantine with it.
- **mtu-blackhole** *(shipped)* — a 1 MB download works and a 1 MB upload to the
  same host on the same port hangs forever. One direction of one link is narrow,
  and the ICMP that exists to say so is dropped by the router that generates it.
  The path MTU has to be measured, because nothing will tell you.
- **tls-chain-and-sni** *(shipped)* — `curl -k` works, the leaf is valid until
  2028, and the client library will not have it. The gateway sends the leaf and
  not the intermediate that signs it, and the deploy script names the host by IP
  address, which puts no server name in the handshake and collects a neighbour's
  certificate. Two faults, two error messages, one ticket.
- **through-a-proxy** *(shipped)* — the egress proxy is configured in
  `/etc/environment`, so login shells have it and systemd services do not, and
  nobody wrote a `NO_PROXY` at all. Each half of the box fails the opposite way,
  and both halves have to be fixed without editing the job that fails.

- **ephemeral-port-exhaustion** *(shipped)* — the load generator fails to
  connect and the server it is pointed at is idle. Two hundred ephemeral ports,
  a client that hangs up first, and sixty seconds of TIME_WAIT each: the box runs
  out of source ports and reports it as though the far end had done something.

- **ssh-without-locking-yourself-out** *(shipped)* — the change is one line and
  the danger is the order: no key works yet, and the file everyone edits is
  outranked by a drop-in that is read first. Graded from the other box, because
  a key login tested from the box you are already on proves nothing.

- **spf-dkim-dmarc** *(shipped)* — the mail arrives and is filed as spam. A
  receiving MX checks the message for real and says why: an SPF record naming a
  relay that was replaced, a DKIM signature with no published key, and no DMARC
  record to bind either of them to the address the human reads.

- **pattern-layered-triage** *(shipped)* — one symptom, and the fault is drawn
  at random from five: a permanent neighbour entry with a MAC nothing answers
  to, a deleted route, a `drop` for one port on the router in the middle, a name
  that resolves to an address no interface owns, a certificate for another host.
  The drill is the ladder — frame, next hop, port, name, certificate — walked in
  order until a rung answers, and the layer has to be named as well as repaired.

### 06 — Web Servers & Proxies
`web-stack`

- **serve-a-static-site** *(shipped)* — every request is 403 on a file that is
  0644 and readable by root. Opening a file is one permission check per path
  component, and the one that refused is a directory above the one being
  stared at: execute on a directory is permission to traverse it, and without
  it nothing underneath can be reached however permissive it is.

- **trailing-slash-proxy-pass** *(shipped)* — four routes, four 404s, and the
  404s are the application's own. `proxy_pass` with a URI part replaces the text
  the location matched; without one it forwards the request URI untouched. Both
  mistakes are in the file at once, and each fix is one character.

- **502-vs-504** *(shipped)* — one dashboard line covering two failures with
  nothing in common. A 502 says the upstream could not answer at all; a 504 says
  the proxy stopped waiting, on a deadline it chose itself. One is repaired at
  the far end and one on the proxy — per route, because the blanket raise turns
  a single slow dependency into every worker being held.

- **health-check-that-lies** *(shipped)* — two backends, one that cannot serve
  a request, and a load balancer that reports both healthy because the endpoint
  it polls only proves the process is running. Liveness answers "restart me";
  readiness answers "give me traffic", and a load balancer wants the second.
  Then the interval decides how many requests fail before it acts.

- **stale-cache** *(shipped)* — the cache key drops the query string, so every
  fingerprinted URL is one entry and the deploy is invisible; and `Vary` is
  ignored, so one user's page is stored for everyone. Fixing the rules does not
  rewrite what was stored under the old ones, and "purge on every deploy" is the
  workaround that keeps the bug.

- **413-and-buffering** *(shipped)* — a round-numbered upload limit and an
  application with no record of the requests that hit it. The proxy answered on
  its own, because by default it reads the entire body to disk before the
  upstream is contacted at all. Raise the limit, do not remove it, and decide
  deliberately between spooling and streaming.

- **real-ip-and-rate-limits** *(shipped)* — `$remote_addr` is the last hop, so
  every per-client decision made behind a proxy is really a per-proxy decision.
  The header that carries the client is written by whoever is talking to you:
  trust only the entries your own proxies appended, walking the chain from the
  right, or the limiter becomes opt-in.

- **websocket-upgrade** *(shipped)* — a handshake that asks HTTP to stop being
  HTTP, using two headers a proxy is required to consume rather than pass on;
  and then a connection whose normal behaviour, saying nothing for minutes, is
  exactly what every read timeout exists to kill.

- **caddy-automatic-https** *(shipped)* — a certificate that expired for the
  third time this year, installed by hand and renewed by remembering to. An
  internal CA on the same box speaks ACME, which is the protocol a server uses
  to obtain a certificate rather than be handed one; the proof it worked is the
  grader throwing the certificate away and getting another without a human.

- **waf-regex-backtracking** *(shipped)* — the Cloudflare 2019 postmortem, on
  one box. A filter nginx consults with `auth_request` runs one rule per
  request, and the rule contains two adjacent `.*`: six seconds to decide that
  an ordinary URL is fine. Rewriting the rule keeps its verdicts and removes the
  search; a per-rule budget is what makes the next bad rule survivable rather
  than fatal.

### 07 — Security Hardening & Access Control
`linux-box`

AppArmor, not SELinux: every sandbox is Debian, and SELinux does not enforce
meaningfully inside a container. The mechanism transfers; the tool differs, and
each lesson says so.

- **predict-who-can-read** *(shipped)* — seven files, two accounts, and the
  question answered before anything is run. Two cases come out backwards
  because the kernel consults exactly one permission class — owner, else group,
  else other — and a file you own with `----r-----` is one you cannot read
  however many groups you are in. The rest is the path walk: `x` on every
  directory above a file, and a symlink's own mode meaning nothing at all.

- **nopasswd-shell-escape** *(shipped)* — deploybot has two passwordless sudo
  grants, and the one that reads like the smaller privilege (run `awk`) is a
  root shell, because `awk` runs a program you hand it and sudo runs it as root.
  The fix is not tighter arguments — no argument pins a language interpreter —
  it is seeing that the log-reading the grant was for never needed root, and
  keeping only the single-purpose `systemctl restart` line.

- **setuid-hunt** *(shipped)* — two setuid-root backdoors planted among nine
  legitimate setuid binaries that look identical to them. The search is a
  one-liner; the trap is the fix, because the blunt `find -perm -4000 | chmod
  u-s` that kills the backdoors kills sudo too. The signal that separates them
  is provenance: a legitimate setuid binary is owned by a package, and `dpkg -S`
  says so. Also why `ping` is no longer in the list.

- **ssh-hardening** *(shipped)* — sshd accepts root and password logins and
  both have to go, but disabling passwords before the replacement key works
  locks the account out permanently. The lesson is the order: install the key,
  prove it, then take passwords away — validating with `sshd -t` and applying
  with `reload`, never `restart`, so a mistake cannot drop the daemon you are
  reaching it through.

- **systemd-drop-privileges** *(shipped)* — a web service runs as root for one
  reason: to bind port 80. Dropping it to www-data is one line and breaks the
  bind, because a privileged port needs privilege. The fix grants back exactly
  `CAP_NET_BIND_SERVICE` through `AmbientCapabilities`, caps the bounding set to
  it, and sets `NoNewPrivileges` so the reduced privilege sticks — verified by
  reading `CapAmb`/`NoNewPrivs` from `/proc`, not the unit file.

- **fail2ban-bans-the-lb** *(shipped)* — an sshd jail counting failed logins,
  where every failure arrives from the load balancer's address because that is
  the only source the box sees behind it. Twelve failures, one apparent
  attacker, and it is the address every user shares — so the ban takes the whole
  site down. `ignoreip` exempts the load balancer and stops the outage; the
  prose is honest that it also blinds the jail until the real client address is
  logged. Graded offline via `fail2ban-client -t`/`-d` and `fail2ban-regex`,
  since the sandbox kernel has no iptables to ban with.

- **patch-without-reboot** *(shipped)* — a shared library is patched on disk
  but every already-running service still has the old copy mapped in memory,
  marked `(deleted)`, still executing the vulnerable code. Rebooting fixes it and
  takes the whole box down; the skill is scanning `/proc/*/maps` for the stale
  mappings, mapping each pid to its service, and restarting exactly the two
  affected ones — the manual form of what `needrestart` automates.

- **file-integrity-baseline** *(shipped)* — an integrity monitor reports
  sixteen changed files: fifteen are today's deploy rewriting the app, one is a
  `NOPASSWD: ALL` line an intruder hid in the noise. The monitor watches the one
  directory guaranteed to change every release, so its report is useless exactly
  when it matters. The fix is scope — stop watching what a deploy is built to
  change — not re-baselining over the tampered state, which the grader rejects.

- **attack-surface-audit** *(shipped)* — the capstone: two services listen,
  a public portal on :80 and an unauthenticated internal metrics API bound to
  every interface on :9000, answering system telemetry to the whole network.
  The threat model starts by enumerating what a box exposes and to whom;
  intended exposure versus actual is the finding. Restrict the API to loopback
  without over-correcting and taking the portal — public by design — offline.

Still to build: an AppArmor denial in enforce mode and auditd answering who
changed the file at 02:14 — both blocked by this sandbox's kernel (no AppArmor
LSM, no audit subsystem), to be reframed or moved to a VM-backed sandbox.

### 08 — Version Control
no sandbox, except `git-box` for the LFS lesson

- **branch-commit-merge** *(shipped)* — the loop everything else in this module
  reads the output of, done once on purpose. main has not moved since the branch
  was cut, so the default merge fast-forwards: it slides main's pointer to the
  branch tip and writes nothing, leaving three commits in a row that are
  indistinguishable from three typed straight onto main. `--no-ff` records the
  merge instead, and the two-parent commit is what says which commits were a
  unit, when they landed, and what to revert to undo the feature. The grader
  requires both branch commits on the tip's *second* parent, so a squash or a
  re-commit onto main fails, and when the tip has one parent it checks whether
  the branch still exists before telling the student which mistake they made.

- **bisect-a-regression** *(shipped)* — a calculator's test passed sixty-five
  commits ago and fails at the tip, and the breaking commit is titled like an
  innocent one. `git bisect run` finds it by binary search in about six steps
  instead of sixty-five, driven by the test's own exit code. The grader runs the
  same search to compute the true culprit, so only the exact commit passes and a
  near-miss is told which side of the boundary it is on.

- **reflog-recovery** *(shipped)* — a hard reset on the wrong branch drops
  three commits from main; the files are off disk and git log shows only the
  base. reset --hard moves a pointer, it does not delete commits, so the reflog
  still holds the lost tip and pointing the branch back restores everything. The
  grader checks the recovered work is committed and reachable (all files in
  HEAD's tree, VERSION at v2.0), not just typed back by hand.

- **secret-in-history** *(shipped)* — a gateway token was committed in
  deploy/config.yml and a later commit deleted the file, so the tip is clean and
  every clone still carries it. A commit that removes a file leaves the blob
  reachable; the commits have to be rewritten. `filter-branch --index-filter`
  does it, and then leaves the pre-rewrite tips under `refs/original/`, where
  they keep the old commits — and the secret — reachable until they are deleted.
  The grader scans every object reachable from every ref, and fails an answer
  that purged the value without recording that the token still had to be rotated.

- **rebase-or-merge** *(shipped)* — a hotfix on main caps a discount at ninety
  percent; a branch cut before it rewrote the same function to add a tier bonus.
  Each side shipped its own test, so the code and the tests conflict together and
  `-X theirs` resolves them together — dropping the cap and the test that guards
  it, which leaves the suite green with the bug back. During a rebase `ours` is
  the branch being replayed onto, not the branch you are standing on, so the `-X`
  that looks like it protects your work is the one that discards it. The grader
  ignores the learner's suite and calls the function itself, including the case
  that only the two changes in the right order get right.

- **hooks-that-catch-it-earlier** *(shipped)* — the same credential, refused at
  the commit that would have introduced it. The fixture repo is built to punish a
  loose pattern: the docs document `api_token`, a test fixture holds a fake
  `access_token`, the lockfile carries a 64-character hex hash, and the
  developer's own gitignored `.env` holds a live token — so a hook that scans the
  working tree blocks every commit in the repository, and one that greps the
  staged diff for a word blocks a comment, because a diff carries context lines
  that were already committed. The grader commits six times in a copy of the
  repository and, when the first allowed commit is refused, probes with an empty
  commit and with the `.env` moved outside the tree to say which of the three
  mistakes it is. The written answer has to reach the point of the lesson: the
  hook is one `--no-verify` away and `.git/hooks` is not cloned, so it is a fast
  feedback loop and the enforcement belongs server-side.

- **submodule-detached** *(shipped)* — the vendored library's fix is published,
  it is checked out in `vendor/liblog`, and the learner's own build passes;
  every clone still gets the library from before the fix. A submodule is one
  tree entry of mode 160000 naming a commit, so fetching inside the submodule
  moves a working directory and changes nothing a clone can read — `git status`
  reports the disagreement as a modified path. The grader clones the
  application's origin recursively the way CI does and requires that clone to
  build: a parent commit that was never pushed, a gitlink whose commit is not in
  the library's origin, a commit off the library's main, and the library copied
  in as plain files each get their own answer.

- **large-files-and-lfs** *(shipped)* — a six-megabyte sprite atlas regenerated
  every sprint and committed whole, four times: seventeen megabytes of history
  behind two hundred kilobytes of Python, because regenerated binaries share
  nothing to delta against. Deleting the file removes it from the tip and leaves
  every blob reachable, so the clone costs the same and the renderer has lost
  its atlas. `git lfs track` governs future commits only; `git lfs migrate
  import --everything` rewrites the commits that already hold the blobs, and the
  new ids force the push. The grader clones with `--no-local` — a same-disk
  clone copies the object store wholesale and would measure nothing — and wants
  the history under 1 MB with the atlas byte-identical at the tip, telling apart
  a naive delete, tracking without a rewrite, an unpushed rewrite, and pointers
  whose objects never reached the store.

### 09 — Containers · *shipped*
`none` (scratch workspace)

A container is a process with an unusual view of the filesystem and the network.

- **build-run-inspect** *(shipped)* — the job containerises in four lines, runs,
  prints `wrote /out/report.txt`, exits 0, and the host has no report. The write
  went to the container's own writable layer, which is not deleted when the
  process exits — only when the container is, which is what `--rm` would have
  done. Recover it from the exited container with `docker cp`, then bind-mount
  `out/` so the next run needs no rescue. The grader runs the learner's image
  itself and requires both host copies to match what it writes, so a report
  typed by hand fails; `--rm` on the run fails for the reason the lesson is
  about.
- **pid1-signals** *(shipped)* — `docker stop` takes exactly ten seconds, every
  time, and the shutdown handler never runs. What PID 1 means, and what
  shell-form `CMD` really does.
- **layer-cache-and-size** *(shipped)* — 1.16 GB image, and every commit rebuilds
  the world. Order layers by change frequency; ship only what runs.
  1158 MB → 149 MB.
- **compose-networking** *(shipped)* — the API can't reach Redis and both are
  healthy. What `localhost` means inside a container, and why publishing a port
  didn't help.
- **uid-mismatch-on-a-volume** *(shipped)* — the security review asked for a
  non-root user, and the service stopped writing the volume it shares with the
  exporter. A fresh named volume is root-owned 755 and stays that way until
  something changes it, so ownership is decided by whichever container writes
  first — here a vendor image running as root. `chmod -R 777` clears the error
  and restores exactly the permission model the review objected to, so the
  grader rejects any world-writable path and requires the whole volume to belong
  to the uid the app reports at runtime; which uid that is, is the learner's
  choice. The written fix is a one-shot `chown` service ordered between the two
  with `service_completed_successfully` — `initContainer` and `fsGroup` in the
  spelling they will meet next.
- **secrets-in-layers** *(shipped)* — the build decrypts a licensed asset, so CI
  passes the key with `--build-arg`, and BuildKit records it against every
  instruction that ran with it: `RUN |1 LICENSE_KEY=...`, readable by anyone who
  can pull. The two hiding places are graded separately, because the fixes for
  them are different and each is a plausible half-answer: history and config
  carry the instructions, the layers carry the bytes, and `rm` in a later layer
  writes a whiteout over a snapshot it cannot edit. `RUN --mount=type=secret` is
  the answer; a multi-stage build that copies out only the artefact also passes,
  with the caveat about the builder stage's cache written up in the lesson.
  Decrypting on the host and copying the plaintext in is rejected by name, and
  the lesson closes on rotation: every fix changes the next image, not the one
  already published.
- **dockerignore-and-context** *(shipped)* — a hundred-line app with 106 MB of
  build context: `.git`, the frontend's `node_modules`, a virtualenv, fixtures
  and a build log, uploaded before the first instruction is read and then copied
  into the image by `COPY . .`. The fix everyone reaches for — narrowing the
  `COPY` lines — shrinks the image and moves the transfer not at all, because the
  client packs the directory before the daemon reads the Dockerfile, so the
  grader measures what the daemon receives rather than what the image kept.
  `.gitignore` is not consulted, and an exclusion wide enough to take
  `web/dist` is caught by running the image. 106.10 MB becomes 297 bytes.
- **healthcheck-semantics** *(shipped)* — the API answers every request and
  Docker reports it unhealthy, so nothing deploys. The check shells out to
  `curl`, which is not in `python:3.12-slim`, and a missing command exits 127
  like any other failure. Fixing that exposes the problem it was hiding: the
  check asked `/`, which answers from the moment the process listens, while the
  price cache takes ten seconds to load and `/price` answers 503 throughout —
  so the honest check goes red during a legitimate warm-up, three retries run
  out inside it, and `up --wait` fails on unhealthy. `--start-period` is the
  third change. The grader runs the student's own check command inside the
  container, cold and then warm, so a check tuned to pass by interval alone
  cannot fake it, and it tells apart a deleted check, a check on the wrong
  route, a missing start period, and a warm-up removed from the app.
- **exec-format-error** *(shipped)* — `exec /usr/local/bin/app: exec format
  error` on the runner, and the same tag runs on the laptop, because an arm64
  binary in an amd64-labelled image runs fine on arm64: the label is not
  consulted when the file is executed locally. Two bugs in series, and the
  second is why the first guess fails. Adding `--platform linux/amd64,linux/arm64
  --push` produces a manifest with both entries and an amd64 image that still
  dies, because `FROM --platform=$BUILDPLATFORM` pins the toolchain stage to the
  build machine and nothing told the compiler what it was building for. The
  grader reads the ELF header of the binary inside each published image rather
  than trusting the manifest, so a build that satisfies the inspection and ships
  the wrong bytes is caught. Scenario runs a local registry, because manifest
  lists live in registries and `--load` cannot hold one.
- **memory-limit-and-oom** *(shipped)* — exit 137 with no stack trace, at the
  same input size every run, which is already the evidence that it is not the
  leak everyone assumes: a leak grows with time, this grows with input.
  `mem_limit: 512m` against `-Xmx1g` — the JVM allocates toward its own ceiling,
  crosses the cgroup on the way, and the kernel removes it before it can react.
  Both halves are required and each is checked from the running container rather
  than the compose file: the limit is read from the container's own cgroup and
  capped at the node pool's 1 GiB, and the heap ceiling is read back out of the
  JVM and must leave 128 MB for metaspace, stacks, code cache and buffers. The
  last check is the one that makes the point — the same image with 20,000,000
  records must fail with `OutOfMemoryError` instead of 137, because tuning the
  heap under the limit decides which subsystem notices first, and only one of
  them leaves a diagnosis.
- **logs-that-fill-the-disk** *(shipped)* — a healthy service, unchanged for six
  weeks, fills the host every Thursday: a container's stdout is a file on the
  daemon's host that grows for the life of the container and that nothing
  rotates unless told to. Deleting it frees nothing, because the daemon holds it
  open and unlinking removes the name rather than the data — `disk-full-triage`
  from module 01, met from the other side. The grader measures what the image
  emits by running it itself with no log options, so quieting the service fails
  instead of passing, then requires the retained log to be a fraction of that,
  still readable, and still ending on the line the service finished with.
  `driver: none` bounds the disk perfectly and is refused by name.
- **rootless-and-capabilities** *(shipped)* — the egress shaper failed with
  `Operation not permitted`, someone added `privileged: true`, and that was
  eighteen months ago. Root in a container is not one privilege but a set of
  capabilities, of which Docker already withholds most; `NET_ADMIN` is the one
  `ip link set mtu` and `tc qdisc add` need and the one the default fourteen do
  not include. The grader requires the effective set to be exactly that single
  capability, so `cap_add` without `cap_drop: ALL` is rejected with the fourteen
  defaults decoded and listed, and it proves the reduction behaviourally by
  requiring a tmpfs mount inside the container to be refused — `CAP_SYS_ADMIN`
  being what `privileged` was really handing over.

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

- **run-it-on-every-push** *(shipped)* — a workflow that was written during
  onboarding, reviewed, merged, and has produced no build of either colour in
  four months: `on: workflow_dispatch` is a list of one event and a push is not
  on it, and the single step is `npm test || true`. Two defects, each of which
  leaves a useless pipeline when fixed alone, so the grader checks them
  separately: the tip of main must carry a finished successful run, and then it
  pushes a commit whose tests genuinely fail and requires red, force-pushing the
  repository back afterwards. Green is only worth something where red is
  reachable, which is the first thing to establish about any new pipeline.
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
- **cache-poisoned-green** *(shipped)* — installs were dominating the build, so
  someone cached `node_modules` under `key: node-modules-${{ runner.os }}` and
  skipped `npm ci` on a hit. Read as a sentence, that key claims every Linux
  build forever may share one dependency tree, whatever the repository asks for
  — so a dependency upgrade is tested against the packages from before it, goes
  green, and breaks production. The grader measures rather than reads: it pushes
  a commit changing only package.json and the lockfile, to a vendored version
  that removes a function the code calls, and requires red. A key hashing the
  wrong input passes inspection and fails that, and deleting the cache step is
  refused separately, because the ninety seconds it saves are why it exists.
  Also measured and written up: `restore-keys` stays safe here, since `cache-hit`
  is only true on an exact match, so the install still runs.
- **matrix-and-fail-fast** *(shipped)* — the suite is sharded three ways and
  branch protection wants one required check, so a `gate` job waits on the
  matrix with `if: always()` and a step that echoes. `needs:` is an edge in a
  graph rather than an assertion, and `always()` removes the one default that
  was doing the checking, so the gate is a green light wired to nothing. Tangled
  with it deliberately: the integration shard fails its first attempt in a fresh
  container, which is why nobody looked hard at the red shard. Both halves are
  required — fixing the gate alone turns a flaky suite into a red main, and
  retrying alone leaves the gate lying — and the grader checks them separately,
  by reading the named check's own status rather than the commit's aggregate,
  which on Forgejo is honest. Retry versus ignore is the distinction the lesson
  turns on: three attempts still fail on a test that is genuinely broken.
- **promote-do-not-rebuild** *(shipped)* — build, deploy to staging, deploy to
  production, all green, and the production job checks the same commit out and
  builds it a second time. Same source, different bytes: the image stamps the
  build it came from, and that is only the most visible of the things a rebuild
  does not hold constant — the base image behind its tag, whatever the package
  manager resolves today, the builder version. So whatever staging proved, it
  proved about an artefact production is not serving. The fix is one build under
  an immutable `git-<sha>` tag and a deploy that is a `docker tag` and a push
  that uploads no layers. Two wrong answers are refused by name: pinning both
  environments to one image, which agrees perfectly and never ships anything,
  and freezing the build stamp so the two rebuilds match, which buys the digest
  check by destroying the ability to tell two builds apart. Graded against the
  registry, on the manifest digest each environment's tag resolves to.
- Then: the branch protection with a path around it · two merges racing to
  deploy · one Jenkinsfile lesson, because enterprises still run it · and the
  Cloudflare 2019 postmortem as a staged rollout.

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
