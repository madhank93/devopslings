# Exercise inventory

Every exercise this course intends to ship, with enough design in each entry to
build it without re-deciding what it teaches. `CURRICULUM.md` says what a module
is *about*; this file says what you will actually be doing in it.

## How to read an entry

```
- **slug** *(tier · status)* — the scenario, in the state the student meets it.
  *First guess:* the thing most people try, and why it does not hold.
  *Check:* what the grader measures — the thing that cannot be faked.
  *Source:* where the idea came from.
```

Three rules that shaped every entry:

1. **The check measures the cause, not the symptom.** If a student can pass by
   restarting something, the exercise is not finished.
2. **The first guess is wrong on purpose.** An exercise where the obvious move
   works teaches nothing that a man page would not. *Exempt:* `intro` entries,
   where the goal is fluency with a tool rather than diagnosis, may have no
   wrong first guess at all.
3. **Ideas travel, artefacts do not.** Where an entry is marked *SadServers-style*
   or *iximiuz-style*, that names a family of failure that those platforms also
   teach — the scenario, names, numbers and checks here are written from scratch.
   See the originality rule at the end of `CURRICULUM.md`.

## Difficulty tiers

| Tier | What it asks of you |
|---|---|
| **intro** | One concept, guided. Fluency with a tool, not diagnosis. The rung that lets someone who has never written a systemd unit start here. |
| **core** | The repo's standard shape: a system already broken, an obvious first guess that is wrong, and a check that measures the cause. |
| **deep** | Requires measurement or a mechanism below the tool's surface — a profile, a packet capture, a kernel counter, an arithmetic argument. |
| **architect** | A written decision or design, graded against a rubric. No single right command, and no way to pass by typing faster. |

**Status**: *(shipped)* passes the contract test · *(next)* queued for the
current wave · *(blocked)* specified, and the sandbox cannot currently produce
the failure honestly — the entry says what it would take · everything else is
specified and unbuilt.

**Counts**: 274 exercises across 27 modules and 11 sandboxes. 64 shipped,
210 specified. Modules 01–04 are complete: all 47 of their exercises pass the
contract test. By tier: 29 intro · 154 core · 60 deep · 31 architect.

Per module: 01/18 · 02/9 · 03/10 · 04/10 · 05/12 · 06/10 · 07/11 · 08/8 · 09/12 ·
10/14 · 11/9 · 12/11 · 13/10 · 14/6 · 15/6 · 16/7 · 17/10 · 18/10 · 19/9 ·
20/15 · 21/13 · 22/11 · 23/10 · 24/13 · 25/7 · 26/9 · 27/4.

Every module opens at the tier its prerequisites allow. Modules 01–23 and 25
each have an `intro` rung. Modules 24, 26 and 27 do not, because they are built
entirely on earlier modules — starting there is the mistake, not the on-ramp.

---

## 01 — Linux & Terminal Triage
`linux-box` · 18 exercises · 18 shipped · 4 intro · 12 core · 2 deep

- **find-the-evidence** *(intro · shipped)* — a service misbehaved an hour ago and its own
  log file is empty. Four places hold evidence: the unit's journal, `dmesg`, the
  files under `/var/log`, and the process's open file descriptors.
  *Check:* the answer file names which of the four held the record, and quotes
  the line — a guess that names the right place with the wrong line fails.
  *Source:* own; the skill every later module assumes and none teaches.

- **package-held-back** *(intro · shipped)* — `apt upgrade` says one package was kept back
  and exits 0. The security fix everyone believes is installed is not.
  *Check:* the package is at the fixed version, the reason it was held is named,
  and `apt-mark showhold` is clean.
  *Source:* own; roadmap.sh package-management gap.

- **write-a-unit** *(intro · shipped)* — a working script and no unit. Write one.
  *Check:* the service starts on boot, restarts on failure, comes up after its
  dependency rather than alongside it, and logs to the journal — `Type=`,
  `Restart=`, and `After=` versus `Requires=` all exercised.
  *Source:* own; the counterpart to systemd-unit-failure, from the other side.

- **users-groups-sudoers** *(intro · shipped)* — the user is in the group and still cannot
  read the file.
  *First guess:* the group membership did not apply — re-add the user.
  *Check:* access works in a fresh login session, and the answer names why the
  running shell never saw the new secondary group.
  *Source:* own.

- **disk-full-triage** *(core · shipped)* — `/var/log/app` is at 91% and `du` finds 12 KB.
  *First guess:* delete the big file — space does not come back.
  *Check:* free space holds after the deleting process is dealt with properly.
  *Source:* own; the deleted-but-open-fd family is universal.

- **runaway-process** *(core · shipped)* — four processes, one is eating the box.
  *First guess:* kill the one at the top of `top`.
  *Check:* the actual offender is gone and the other three still run.
  *Source:* Brendan Gregg's 60-second checklist.

- **systemd-unit-failure** *(core · shipped)* — `status=1/FAILURE` and nothing else.
  *First guess:* `systemctl restart`, which hits the start rate limit.
  *Check:* service active, config on disk, survives a restart, enabled.
  *Source:* own.

- **cron-and-path** *(core · shipped)* — the backup works by hand, writes nothing at 03:17.
  *First guess:* run it again by hand and declare it fixed.
  *Check:* real cron runs the student's crontab line and produces the backup.
  *Source:* own; `%` and `PATH` are the two classic cron bites.

- **text-at-scale** *(core · shipped)* — three exact answers out of a 390k-line log.
  *First guess:* `grep -c 503` — returns 202,127 against a true 8,493.
  *Check:* the three answers, recomputed from a fingerprinted log.
  *Source:* roadmap.sh gap (text processing is assumed everywhere, taught nowhere).

- **permissions-triage** *(core · shipped)* — a service cannot write to a directory it owns.
  *First guess:* `chmod 777`, which fixes it until the next file is created.
  *Check:* the check starts the service and inspects the *new* file — owner,
  group, mode, and whether the consuming account can read it; world-writable
  anywhere in the tree fails.
  *Source:* own; setgid + umask, which are two mechanisms and not one.

- **signals-and-detach** *(core · shipped)* — the long job dies every time the SSH session drops.
  *First guess:* `&` on the end of the command, which changes nothing.
  *Check:* the job survives a hangup delivered to the session, and the answer
  distinguishes the process group from the session leader.
  *Source:* own.

- **journal-eats-the-disk** *(core · shipped)* — a healthy box runs out of space in three weeks.
  *First guess:* `rm` the journal files, which the running journald keeps open.
  *Check:* journal size bounded under a sustained write, with the history the
  retention policy promises still queryable.
  *Source:* own; callback to disk-full-triage.

- **blocked-on-a-pipe** *(deep · shipped)* — a job hangs forever at 0% CPU with no error.
  *First guess:* it is deadlocked in the application, so restart it — which
  destroys the evidence and blocks again in the same place.
  *Check:* `/proc/<pid>/wchan` is recorded from the live process, and the
  pipeline is torn down and re-run to a byte-exact output.
  *Source:* own; a FIFO writer whose reader never arrived.

- **oom-killed** *(core · shipped)* — a worker vanishes nightly with no log line of its own.
  *First guess:* the app crashed; add a `try/except`.
  *Check:* the kernel's OOM record is quoted correctly and the process survives
  the same workload after the limit or the allocation is fixed.
  *Source:* SadServers-style (OOM triage is a staple).

- **too-many-open-files** *(deep · shipped)* — `EMFILE` under load, fine when idle.
  *First guess:* raise `ulimit -n` in your shell; the service does not inherit it.
  *Check:* the limit is raised where systemd reads it *and* the fd leak is gone —
  fd count stays flat across a second load run.
  *Source:* own.

- **inodes-not-bytes** *(core · shipped)* — writes fail with `ENOSPC`, `df -h` says 40% free.
  *First guess:* look for a big file; there isn't one.
  *Check:* `df -i` usage back under threshold with the payload directory intact.
  *Source:* SadServers-style.

- **zombies-and-the-reaping-parent** *(core · shipped)* — the process table fills with
  entries that are already dead.
  *First guess:* `kill -9` them, which does nothing — a zombie is not a process,
  it is an exit status nobody has collected.
  *Check:* the answer names why the signal has no effect, and the parent is
  fixed so the zombie table stays empty under sustained load.
  *Source:* own. **Rescoped:** this was `d-state-and-zombies`. The D-state half
  is not reproducible on `linux-box` — the cgroup freezer yields `S` in
  `do_freezer_trap` and a frozen task still dies from `SIGKILL`, so there is no
  honest unkillable process without a wedged mount. That half now lives in
  module 04 as `d-state-and-the-wedged-mount`, where an NFS server can be taken
  away mid-read.

- **clock-skew** *(core · shipped)* — TLS handshakes fail for one service only.
  *First guess:* the certificate is bad; regenerate it. The certificate is
  correct, the chain verifies, the SAN matches, and `curl` from the shell works.
  *Check:* the cause is named, verification is still enabled, and the time the
  *service itself* reports is within two minutes of the box — so a handshake
  made to succeed some other way fails.
  *Source:* own. The skew is injected with `libfaketime` via `LD_PRELOAD` on the
  one unit, because a container shares the kernel wall clock with its host —
  time namespaces virtualise only `CLOCK_MONOTONIC` and boottime, and `date -s`
  inside the box would move the clock for every container on the machine. The
  lesson says so.

---

## 02 — Scripting & Automation
`linux-box` · 9 exercises · 9 shipped · 2 intro · 5 core · 1 deep · 1 architect

The roadmap says "learn a programming language" and stops. This module is the
part that actually bites: a script that works on your machine, on your files,
once, and then runs at 03:00 against input you did not imagine.

- **unquoted-and-broken** *(intro · shipped)* — the archive script works until a filename
  gains a space, then deletes the wrong thing.
  *Check:* the script handles spaces, newlines and a leading dash in filenames,
  proven against a fixture directory built to contain all three.
  *Source:* own.

- **arguments-and-usage** *(intro · shipped)* — a script with three positional arguments
  nobody can remember the order of.
  *Check:* named flags with defaults, a usage message on `-h`, and a non-zero
  exit with a specific message when a required argument is missing.
  *Source:* own.

- **exit-codes-and-pipefail** *(core · shipped)* — the nightly job reports success and
  produced nothing.
  *First guess:* the last command worked, so the script worked.
  *Check:* the pipeline's real failure is surfaced and the script exits non-zero;
  a seeded mid-pipe failure must not pass.
  *Source:* own; `$?` is the last stage only.

- **set-e-does-not-do-that** *(core · shipped)* — `set -e` is at the top and the failure
  still sails through.
  *First guess:* add `set -e` harder, or `set -euo pipefail` and assume it is done.
  *Check:* the four contexts where `set -e` is suspended — `if`, `&&`/`||`,
  command substitution in an assignment, and a function called in a condition —
  are each handled, verified by a seeded failure in every one.
  *Source:* own; the most confidently misunderstood line in shell scripting.

- **idempotent-by-construction** *(core · shipped)* — the provisioning script works once
  and corrupts the box on the second run.
  *First guess:* add a "has this run before" flag file.
  *Check:* running it three times leaves the same end state as running it once,
  including after an interrupted middle run.
  *Source:* own; the property module 15 makes Ansible's whole argument.

- **trap-and-cleanup** *(core · shipped)* — every interrupted run leaves a 2 GB temp
  directory behind, and there are forty of them.
  *First guess:* delete the temp directory at the end of the script.
  *Check:* the temp directory is gone after a normal exit, after an error exit,
  and after `SIGINT` mid-run — all three tested.
  *Source:* own.

- **parse-do-not-scrape** *(core · shipped)* — the log parser breaks when a field gains a space.
  *First guess:* widen the regex, which then matches the wrong field.
  *Check:* the parser reads the structured field correctly for every record in
  the fixture, including the three records with embedded spaces and quotes.
  *Source:* own; the `jq`-not-`awk` boundary.

- **python-for-the-api** *(deep · shipped)* — a report script that quietly misses 40% of records.
  *First guess:* one request, read the list, done — page one of nine.
  *Check:* all records retrieved across pagination, rate-limit headers respected
  rather than slept through, and a transient 503 retried with backoff — the
  fixture API returns all three conditions.
  *Source:* own; where bash should have stopped.

- **when-bash-stops** *(architect · shipped)* — four real scripts, one decision each.
  *Check:* the answer file picks shell or a program for each and cites the
  constraint that decided it — dependency management, testability, data
  structures, or error handling — graded against a rubric that rejects
  "it felt cleaner".
  *Source:* own.

---

## 03 — Storage, Filesystems & the Kernel
`linux-box` (loop devices, LVM, cgroup v2) · 10 exercises · all shipped ·
1 intro · 4 core · 4 deep · 1 architect

Where "the disk is slow" and "we are out of memory" turn out to be four
different things each.

- **mount-and-fstab** *(intro · shipped)* — a typo in `/etc/fstab` and a box that stops
  half way through boot.
  *Check:* the filesystem mounts at boot with the right options, and the answer
  names the field that was wrong and what `nofail` would have changed.
  *Source:* own.

- **lvm-extend-under-pressure** *(core · shipped)* — 96% full, a spare disk, and a live service.
  *First guess:* extend the logical volume and call it done — the filesystem
  never learned about the new space.
  *Check:* free space visible to the application, both steps done in the right
  order, with the service serving throughout.
  *Source:* own.

- **uuid-not-device-name** *(core · shipped)* — after a reboot the data volume mounted at
  the log path and vice versa.
  *First guess:* swap the device names back in `fstab`.
  *Check:* mounts are stable across two reboots with a device added in between —
  a `fstab` still keyed on `/dev/sd*` fails.
  *Source:* own.

- **swap-and-swappiness** *(core · shipped)* — a batch job is nine times slower on a
  box with gigabytes free, because it is paging against a limit that is not the
  machine's.
  *First guess:* add memory, or turn swap off.
  *Check:* `pswpin` is named from the unit cgroup's `memory.stat` as the
  evidence that separates a large job from a paging one, and the pass rate
  recovers under the same input without the job being OOM-killed. Turning swap
  off fails — the job is killed instead — and so does shrinking the work or
  touching `vm.swappiness`.
  *Source:* own. **Rescoped to a cgroup.** Swap is machine-wide: a container
  shares `/proc/swaps` and `vm.swappiness` with its host, so `swapon` or a
  swappiness change inside the box would alter the whole Docker VM. The lesson
  therefore works inside a memory cgroup via `MemoryMax` and `MemorySwapMax`,
  which are genuinely per-unit, and grades a swappiness change as a wrong answer
  with the reason given.

  Worth knowing while writing it: a working set that overflows its limit is
  *not* reliably slow. Read in address order, readahead plus the host's zram
  swap keep an overflowing job within a few percent of a resident one — the
  first draft measured a 9x gap that turned out to be first-touch warmup, and
  in steady state there was no gap at all. The job has to touch its working set
  in key order for the failure to exist. Sequential overflow is cheap; random
  overflow is 11x. Any lesson about paging has to say which one it means.

- **sysctl-that-survives** *(core · shipped)* — the network tuning works until the reboot.
  *First guess:* put `sysctl -w` in `rc.local`.
  *Check:* the setting holds across a restart of the sandbox, is applied by the
  documented mechanism, and the answer names which drop-in was overriding it.
  *Source:* own. Uses a `net.*` sysctl deliberately: network sysctls are
  per-network-namespace and therefore genuinely the container's own, while
  `vm.*` and `kernel.*` are shared with the host and must not be written from a
  lesson.

- **cgroup-cpu-throttling** *(deep · shipped)* — p99 spikes every few seconds and CPU
  utilisation sits at 40%.
  *First guess:* the graph shows spare CPU, so it is not CPU.
  *Check:* `nr_throttled` and `throttled_time` are quoted as the evidence, and
  the p99 recovers after the quota or period is corrected — raising the CPU
  *request* alone does not pass.
  *Source:* own; the single most common invisible latency cause in containers.

- **iostat-await-versus-util** *(deep · shipped)* — one volume at ~83% util that is not
  the bottleneck, and one at ~42% that is.
  *First guess:* the higher util number is the device to replace.
  *Check:* the answer names `audit` as the saturated volume, `await` as the
  column that identifies it, and `residency` as what `%util` measures. Answering
  `queue-depth` is rejected with the numbers: the two volumes sit within half a
  request of each other, so queue depth does not separate them either.
  *Source:* Brendan Gregg's USE method, applied to disks. The contrast is
  produced with real I/O patterns rather than `dm-delay`, which the sandbox
  kernel does not have (see the note under `fsync-and-the-lie`).

  **Rescoped from "await and queue depth" to await alone**, because the measured
  contrast does not support the other half. Getting a device to look busy while
  being healthy is easy — cached random reads through a loop device peg `%util`
  at 83% with 0.04 ms service time. Getting one that is genuinely slow needs
  writes that reach real storage, and `O_DIRECT|O_SYNC` at a throttled arrival
  rate gives 42% util at 1.3 ms per write. Measured side by side: 45x the
  request rate, one thirty-third the service time, and queue depths of 1.93
  against 1.49. Only `await` separates them, which turns out to be the sharper
  lesson — util points the wrong way and queue depth says nothing at all.

  Two things the scenario needs. `iostat` reports device-mapper volumes as
  `dm-1` and `dm-2` regardless of their names, so the probe resolves
  `/sys/block/dm-*/dm/name` and rewrites the column — a report that cannot say
  which volume is which teaches nothing. And the loads run on demand from
  `storage-probe` rather than as always-on services: pegging `%util` from
  userspace costs a core, and a lesson should not hold one for as long as the
  student takes to think.

- **page-cache-versus-rss** *(deep · shipped)* — "the application is leaking 8 GB".
  *First guess:* restart it nightly.
  *Check:* the answer separates page cache from anonymous RSS with evidence from
  `smaps`, and the seeded genuine leak — which is present, and smaller — is
  identified underneath the noise.
  *Source:* own.

- **fsync-and-the-lie** *(deep · shipped)* — the write returned `committed`, exited 0,
  and the record is not there after the power cut.
  *First guess:* the application did not write it.
  *Check:* six records are appended through the student's own tool, the power is
  cut, and all six have to survive. The answer names `page-cache` as the layer
  that lied — `application-buffer` is ruled out by the tool already calling
  `flush()`, and `device-cache` by the volume being a device-mapper target over
  a file with no drive in it. The check also requires a durably-written opening
  balance to come back, so a wiped volume cannot pass as a survived one.
  *Source:* own. The lesson is `flush()` versus `fsync()`, which read like a
  pair and are not one.

  **The power cut is real, and getting one on this kernel took a workaround.**
  `dm-flakey` is the usual instrument and the OrbStack kernel does not have it:

  ```
  $ dmsetup targets
  striped   v1.7.0
  linear    v1.5.0
  error     v1.7.0
  ```

  Three targets, and `error` is enough. Suspending the mapping with
  `--noflush --nolockfs` and swapping the table for an `error` target discards
  everything in flight and refuses everything after, with no filesystem freeze
  and no chance to write back — which is what distinguishes a power cut from a
  shutdown. Loading the `linear` table again is the machine coming back up, and
  ext4 replays its journal on mount. Measured: a `flush()`-only append loses
  every record, an `fsync()`ed append loses none.

  Also worth knowing, and the reason the first attempt produced no device at
  all: `systemd-udevd` is masked in this image, so `dmsetup create` makes the
  mapping without a node under `/dev/mapper`. Every `dmsetup` call that changes
  the table needs `dmsetup mknodes` after it.

- **capacity-from-growth** *(architect · shipped)* — size the volume for the next 18
  months, from a year of daily ingest and a 90-day retention policy.
  *First guess:* average daily ingest times the retention window.
  *Check:* the answer names `peak` rather than `mean`, `trailing` or `median` as
  the window the volume has to survive, computes the rolling maximum to within
  3%, projects it with the fitted growth to within 12%, and lands between 1.1x
  and 1.85x of that — a volume sized to the forecast exactly is rejected, and so
  is one sized at three times it. The grader recomputes the truth from the
  seeded CSV rather than holding a literal, so the lesson stays true if the seed
  moves.
  *Source:* own. The series carries three separate effects — linear growth, a
  month-end batch at 2.5x, and a month-long fiscal year-end close at 2.2x — and
  they are placed so that the mean window (396 GB), the trailing window (470 GB)
  and the peak window (560 GB) are three different numbers. The year-end close
  sits clear of the last 90 days deliberately: with monotonic growth the peak
  window is always the trailing one, and the distinction the lesson is about
  disappears.
  *Source:* own.

---

## 04 — Networking I: Packets, Interfaces & the Kernel Path
`netlab` (two boxes, dual-stack) · 10 exercises · all shipped ·
1 intro · 5 core · 3 deep · 1 architect

Module 05 debugs DNS, TLS and proxies. This one is underneath that: the routing
table, the connection tracker, the accept queue, and the packets themselves.

- **which-route-wins** *(intro · shipped)* — three routes match the destination and
  the correct one is not consulted. Half the partner network answers; the half
  covered by a decommissioned gateway's leftover `/24` does not.
  *First guess:* the route is right there in `ip route show`, so the fault is on
  the far side.
  *Check:* the stale route is gone rather than the working ones, `ip route get`
  no longer resolves through the dead nexthop, and both partner addresses serve.
  *Source:* own.

- **two-default-routes** *(core · shipped)* — the host answers on one interface and not the other.
  *First guess:* the second interface is down; it is up and configured.
  *Check:* both interfaces answer from their own address, with the return path
  symmetric — proven from a peer on each network.
  *Source:* own; the asymmetric-routing family.

- **netns-veth-bridge** *(core · shipped)* — build a container's network by hand.
  *First guess:* it needs Docker.
  *Check:* two namespaces reach each other and the outside world through a bridge
  the student created, and the answer maps each piece to what Docker does.
  *Source:* own; the exercise that makes module 09 stop being magic.

- **nat-and-hairpin** *(core · shipped)* — the published address is reachable from
  everywhere except the subnet the service itself lives on.
  *First guess:* bind to a different address.
  *Check:* the published address connects from inside and outside with the DNAT
  rule still in place, and the answer names why the reply was never
  un-translated.
  *Source:* own. The scenario turns off `net.bridge.bridge-nf-call-iptables`,
  which the Docker daemon enables host-wide: with it on, bridged replies are
  dragged through the IP hooks and conntrack un-translates them by accident, so
  the fault does not reproduce. Off is how an ordinary router behaves.

- **ipv6-preferred-and-broken** *(core · shipped)* — every connection stalls for exactly
  five seconds and then works.
  *First guess:* the DNS server is slow.
  *Check:* connections complete without the stall, with the answer identifying
  the AAAA record that resolved against a route that did not exist — and the fix
  is not "disable IPv6 everywhere".
  *Source:* own.

- **tcp-keepalive-versus-idle-timeout** *(core · shipped)* — a pooled connection is dead and
  both ends believe it is fine, until the next request fails.
  *First guess:* retry the request.
  *Check:* the dead connection is detected within the stated budget, with the
  answer distinguishing the kernel keepalive from the middlebox idle timeout that
  actually dropped it.
  *Source:* own.

- **conntrack-under-load** *(deep · shipped)* — new connections are refused while the box
  is nearly idle.
  *First guess:* the service is out of workers.
  *Check:* `nf_conntrack_count` against `nf_conntrack_max` is quoted as the
  evidence, and the same load completes after the table or the timeouts are
  sized — raising the service's worker count does not pass.
  *Source:* own. **Rescoped to timeouts and contents.** `nf_conntrack_max` is
  exposed read-only outside the initial network namespace — a container cannot
  lower it, and cannot lower it inside a namespace it creates either, so the
  table cannot honestly be driven to full. The lesson therefore works on what is
  genuinely ownable: the table's contents, the per-protocol timeouts, and the
  `insert_failed` and `drop` counters from `conntrack -S`. Worth knowing while
  writing it — `sysctl -w` prints `Operation not permitted` and still exits 0,
  so a check must read the value back rather than trust the exit status.

- **accept-queue-overflow** *(deep · shipped)* — clients see connection timeouts and the
  server logs nothing at all.
  *First guess:* the network is dropping packets.
  *Check:* the overflow counter and `ss -lnt` Recv-Q are quoted, and the drops go
  to zero after both the application backlog and `somaxconn` are corrected —
  fixing only one of the two still fails.
  *Source:* own.

- **read-the-capture** *(deep · shipped)* — a capture, three connections, three different
  failures.
  *First guess:* they all "timed out".
  *Check:* the answer classifies each as retransmission, reset, or zero-window,
  quotes the packet that proves it, and names which end was at fault.
  *Source:* own.

- **l4-versus-l7** *(architect · shipped)* — four requirements, one load balancer choice each.
  *Check:* the answer picks a layer per scenario and cites the deciding
  constraint — TLS termination, header routing, source-address preservation, or
  throughput — including the case where L7 cannot help at all. Rubric-graded.
  *Source:* own.

---

## 05 — Networking II: Protocols & Services
`netlab` · 12 exercises · 10 shipped · 1 intro · 8 core · 2 deep · 1 architect

- **resolve-connect-request** *(intro · shipped)* — one HTTP request, taken apart
  into its three separate steps: the name resolved, the TCP connection opened,
  the request written. Three services, three tickets that all say "connection
  failed", and three different steps at fault: NXDOMAIN, an instant RST, and a
  503.
  *Check:* an answer file records, per service, whether it resolved, whether it
  connected and what status came back — the outputs of `dig`, a bare TCP connect
  and `curl -v` — and names the broken step consistently with those three. The
  check re-probes the box, so an answer describing a scenario that has since been
  "fixed" is rejected: this one is a diagnosis, not a repair.
  *Source:* own; the decomposition every later exercise in this module assumes.

- **dns-ndots-and-search** *(core · shipped)* — resolution is slow and
  intermittently wrong: `api.internal` reaches another team's host. `ndots:5`
  plus a `search` list whose first domain carries a wildcard means the wanted
  record is never consulted.
  *First guess:* the DNS server is broken; `dig @server` works fine — because
  `dig` sends the name as typed and `getaddrinfo` does not.
  *Check:* `getent hosts` returns the right address, the page is served, and the
  resolver's own query log shows no suffixed name was asked for. Counting the
  queries is what separates the fix from reordering the search list, which lands
  on the right address and leaves the wasted lookup in place. The `search` line
  and the wildcard must both survive.
  *Source:* roadmap.sh + the Kubernetes ndots folklore, taught on plain Linux.

- **dig-works-app-doesnt** *(core · shipped)* — `dig` resolves, `curl` does not,
  on the same box one second apart. The `hosts:` line of `/etc/nsswitch.conf`
  names no `dns` source, so `getaddrinfo` never reaches the resolver that `dig`
  has been talking to all along.
  *First guess:* DNS. It is `nsswitch.conf` / `getaddrinfo`, not the resolver.
  *Check:* `getent hosts` returns the address, the page is served, and the answer
  file names the file and the missing source. `/etc/hosts` is refused as a fix —
  it repairs one name and leaves the box with no DNS. `getent hosts localhost`
  must still work, which rejects dropping `files` while adding `dns`.
  *Source:* own.

- **bound-to-the-wrong-interface** *(core · shipped)* — service healthy locally,
  refused instantly from anywhere else, and an nftables ruleset sitting there
  accepting 8080 to take the blame.
  *First guess:* firewall. It is listening on 127.0.0.1.
  *Check:* a listener on the box's lab address serving the page, nothing on
  `0.0.0.0` or on the outside `203.0.113.1`, and the outside namespace still
  refused. `0.0.0.0` is the popular wrong fix and is rejected for exposing the
  service on the outside network. The listener must also *belong to the service*
  — a socat relay in front of an unchanged loopback socket serves the page and
  is rejected.
  *Source:* SadServers-style.

- **drop-versus-reject** *(core · shipped)* — one dependency times out after six
  seconds, another refuses in fifteen milliseconds. Measured 6035ms vs 15ms, from
  the same box to the same network, in the same second.
  *First guess:* both are "the firewall is blocking it" — the difference tells you
  which rule and which direction.
  *Check:* both dependencies serving, and the answer file matching each signature
  to the verdict that produced it. A third rule quarantines a decommissioned host
  and must survive, so `nft flush ruleset` — which clears both symptoms — is
  rejected. Rules must be deleted by handle.
  *Source:* own.

- **mtu-blackhole** *(deep · shipped)* — small requests fine, large payloads hang
  forever. The tunnel's two ends disagree — 1400 leaving the near end, 1500
  leaving the far one — so only the outbound direction is squeezed, and the one
  ICMP that would have said so is dropped by the router that generates it.
  *First guess:* the server is slow on big bodies. A 1 MB *download* from the
  same host on the same port completes, which kills that reading and points at
  one direction of one link.
  *Check:* a 1 MB POST completes, the small request and the 1 MB download still
  work, traffic still runs through the tunnel, the narrow end is still 1400, and
  an answer file carries the measured path MTU (1400) and the largest
  don't-fragment ping payload (1372) — because the ICMP that would have told you
  is the thing that is missing, so the number has to be measured. Widening the
  tunnel and relaying around it both make the symptom vanish and are rejected.
  Three real repairs pass: unblocking the ICMP, a per-route `mtu 1400`, and an
  MSS clamp — the last only when clamped on the *inbound* SYN-ACK, since
  clamping your own SYN changes what you receive.
  *Source:* own; the classic overlay/VPN failure.

- **tls-chain-and-sni** *(core · shipped)* — works in `curl -k`, fails in the
  client library, and fails differently again when the deploy script dials the
  gateway by address. Two faults behind one ticket: a vhost serving the leaf
  without the intermediate that signs it, and an IP literal in a URL, which puts
  no server name in the ClientHello and so collects the default vhost's
  certificate.
  *First guess:* the certificate expired. It expires in 2028. The leaf is fine;
  the chain is not, and the name never arrived.
  *Check:* the gateway verifies for a client whose only anchor is the root — so
  installing the intermediate in this box's trust store is not a way through —
  the publish step completes with verification on and the gateway logs
  `sni=artifacts.corp`, and the neighbouring vhost is still the default and still
  verifies. The answer names the missing intermediate and the vhost that answers
  a nameless handshake.
  *Source:* own.

- **through-a-proxy** *(core · shipped)* — half the egress works, and it is a
  different half depending on who is asking: a login shell reaches the vendor
  and gets 502 from the internal service, the nightly systemd job is the exact
  reverse. `/etc/environment` carries the proxy for login sessions, and systemd
  has never read that file.
  *First guess:* set `HTTP_PROXY` everywhere; internal traffic then breaks,
  because the proxy sits on the perimeter and has no route to the inside.
  *Check:* the job and a login shell both reach the vendor and the internal
  service, with the proxy's own log showing `api.vendor.example` on every run
  and `inventory.corp` on none — so teaching the proxy a route inward is not a
  way through. The vendor's script is checksummed and the perimeter has to
  survive. The answer names the proxy's status for an unreachable origin and the
  file a service does not read.
  *Source:* roadmap.sh.

- **ephemeral-port-exhaustion** *(deep · shipped)* — 199 of 400 requests succeed
  and the rest fail instantly with `Cannot assign requested address`, while the
  server answers by hand without hesitating. A 200-port ephemeral range, a client
  that closes every connection itself, and 60 seconds of `TIME_WAIT` per port.
  *First guess:* the server is out of capacity; it is idle, and the error is
  errno 99 from the local kernel — no packet was ever sent.
  *Check:* the same 400-request run completes with no failures. Connection reuse
  in the generator's config or a wider `ip_local_port_range` both do it;
  `tcp_tw_reuse` alone does not, because the kernel only reclaims a TIME_WAIT
  socket over a second old and the whole run fits inside one — the check says so
  when it sees that knob set. The generator is checksummed, the service has to
  survive, and grading waits out the previous run's sockets first. The answer
  names the errno in words and which end holds TIME_WAIT.
  *Source:* own.

- **ssh-without-locking-yourself-out** *(core · shipped)* — password auth off by
  Friday, on the box you are sitting inside, with no `authorized_keys` anywhere
  yet. Editing `sshd_config` changes nothing: Debian's `Include` is on line one,
  `sshd_config.d/50-cloud-init.conf` says yes, and sshd keeps the *first* value
  it reads.
  *First guess:* edit `sshd_config`, reload, believe the file. `sshd -T` still
  says `passwordauthentication yes`.
  *Check:* graded from the peer container — key login as `deploy` works from
  there, the server offers `(publickey)` and nothing else when asked with
  `PreferredAuthentications=none`, `sshd -T` agrees, and the session that was
  open before the change is still writing its heartbeat. A config sshd will not
  start with shows up as connection refused, which is what being locked out
  looks like from outside. The answer names the overriding file and the
  first-match rule.
  *Source:* roadmap.sh gap.

- **spf-dkim-dmarc** *(core)* — mail from the app lands in spam.
  *First guess:* the mail server is misconfigured; it is the DNS records.
  *Check:* a local MTA authenticates the message on all three, verified by the
  receiving side's headers.
  *Source:* roadmap.sh gap.

- **pattern-layered-triage** *(architect · drill)* — one symptom, cause seeded at
  a random layer.
  *First guess:* start at the application, as everyone does.
  *Check:* the layer and the cause named correctly, then repaired. Repeatable:
  the seeded layer changes each run, so the drill cannot be memorised.
  *Source:* own; OSI-ordered triage as a repeatable drill.

---

## 06 — Web Servers & Proxies
`web-stack` (new) · 10 exercises · 1 intro · 7 core · 1 deep · 1 architect

- **serve-a-static-site** *(intro)* — nginx is running and every request is 403.
  *Check:* the site serves, and the answer names why the permission that was
  missing was on a parent directory rather than on the files themselves.
  *Source:* own.

- **trailing-slash-proxy-pass** *(core)* — every path is off by one segment.
  *First guess:* rewrite rules; the answer is one character in `proxy_pass`.
  *Check:* all four upstream routes return the right body.
  *Source:* own; nginx's most reliable trap.

- **502-vs-504** *(core)* — two failures that look identical in the dashboard.
  *First guess:* restart nginx. Neither is nginx.
  *Check:* each is diagnosed to the correct end (upstream dead vs upstream slow)
  and fixed differently.
  *Source:* own.

- **health-check-that-lies** *(core)* — the LB keeps a broken node in rotation.
  *First guess:* increase the check interval.
  *Check:* the endpoint reflects dependency health; a broken node leaves rotation
  within the deadline, and a healthy one is never ejected.
  *Source:* Google SRE practice, ported to HAProxy/nginx.

- **stale-cache** *(core)* — a deploy went out; users still see yesterday.
  *First guess:* purge the whole cache every deploy.
  *Check:* correct cache keys and `Vary` handling — new content served, and the
  cache hit ratio does not collapse.
  *Source:* own.

- **413-and-buffering** *(core)* — uploads fail at exactly 1 MB.
  *First guess:* the app rejects them; the proxy does.
  *Check:* a 25 MB upload succeeds without disabling limits entirely.
  *Source:* own.

- **real-ip-and-rate-limits** *(core)* — the rate limiter blocks everyone at once.
  *First guess:* raise the limit; it is counting the proxy as one client.
  *Check:* per-client limiting works with a trusted `X-Forwarded-For` chain, and
  a spoofed header cannot bypass it.
  *Source:* own.

- **websocket-upgrade** *(core)* — the socket connects and dies after 60 seconds.
  *First guess:* the client reconnect logic.
  *Check:* upgrade headers and read timeouts pass a 5-minute idle socket.
  *Source:* own.

- **caddy-automatic-https** *(deep)* — certificates that renew themselves.
  *First guess:* copy the nginx TLS config over.
  *Check:* served over HTTPS from an ACME-issued cert (local CA), renewal path
  proven by forcing one.
  *Source:* roadmap.sh.

- **incident-cloudflare-2019** *(architect · replay)* — one regex, global CPU exhaustion.
  *First guess:* scale out.
  *Check:* the pathological pattern is identified and bounded, and the staged
  rollout gate stops it reaching all nodes.
  *Source:* published Cloudflare postmortem, simplified.

---

## 07 — Security Hardening & Access Control
`linux-box` · 11 exercises · 1 intro · 6 core · 3 deep · 1 architect

AppArmor, not SELinux: every sandbox is Debian, and SELinux does not enforce
meaningfully inside a container. The mechanism transfers; the tool differs, and
each lesson says so.

- **who-can-read-this** *(intro)* — one file, three users, and a prediction made
  before anything is run.
  *Check:* the answer predicts access correctly for all three from the mode,
  owner and group alone, then confirms it — including the user who is denied by
  a directory's execute bit rather than by the file's own mode.
  *Source:* own; the rung below permissions-triage in module 01.

- **sudoers-that-grants-root** *(core)* — a NOPASSWD entry that looks narrow.
  *First guess:* it only allows one command, so it is safe.
  *Check:* the escalation path is demonstrated, then closed, and the operator can
  still do the legitimate task — removing the entry entirely fails the check.
  *Source:* own; the shell-escape family (`less`, `find -exec`, editors).

- **setuid-hunt** *(core)* — the estate has one setuid binary that should not exist.
  *First guess:* strip setuid from everything found.
  *Check:* the planted binary is neutralised while `ping`, `sudo` and `su` still
  work, and the answer justifies each one kept.
  *Source:* own.

- **ssh-hardening** *(core)* — an inherited box with password auth and root login.
  *First guess:* change the config, restart, and hope.
  *Check:* key-only auth from a second host, root login refused, `authorized_keys`
  permissions correct, and the pre-existing session still alive at the end.
  *Source:* roadmap.sh; pairs with 05's ssh-without-locking-yourself-out.

- **least-privilege-service** *(core)* — the unit runs as root because it once
  needed port 80.
  *First guess:* leave it; it works.
  *Check:* the service runs as a non-root user with `NoNewPrivileges=`,
  `ProtectSystem=` and `PrivateTmp=`, still serves on the privileged port, and a
  seeded write outside its allowed paths is denied.
  *Source:* own.

- **fail2ban-and-the-false-positive** *(core)* — the ban rule eventually bans the
  load balancer.
  *First guess:* raise the threshold.
  *Check:* the attacker is banned, the health-checking peer never is, and the
  answer names why counting by source address failed behind a proxy.
  *Source:* own.

- **patch-without-reboot-roulette** *(core)* — 40 pending updates and a service
  that cannot take unplanned downtime.
  *First guess:* apply everything and reboot on Friday.
  *Check:* security updates applied unattended, the set genuinely requiring a
  reboot is identified from the running-kernel and library evidence, and the
  service is restarted for the ones that only need that.
  *Source:* own.

- **apparmor-denial** *(deep)* — the service works in complain mode and fails in enforce.
  *First guess:* set the profile back to complain, or disable AppArmor.
  *Check:* the profile is in enforce, the service works, and the specific denial
  from the audit log is quoted — a profile widened to `/** rwk` fails.
  *Source:* own.

- **auditd-who-changed-it** *(deep)* — a config file changed at 02:14 and nobody
  admits to it.
  *First guess:* check the file's mtime and the shell history.
  *Check:* the answer names the user, the process, and the syscall from the audit
  trail, having first written the watch rule that would have caught it.
  *Source:* own.

- **file-integrity-baseline** *(deep)* — a baseline that cries wolf every deploy.
  *First guess:* baseline everything under `/`.
  *Check:* a legitimate deploy produces no alert, the planted binary
  modification does, and the answer justifies what was excluded and why.
  *Source:* own.

- **threat-model-this-box** *(architect)* — one host, written up properly.
  *Check:* assets, entry points, trust boundaries and the missing control,
  graded against a rubric that requires a named attacker capability rather than
  "hackers", and rejects controls with no stated cost.
  *Source:* own.

---

## 08 — Version Control
no sandbox (scratch git repos) · 8 exercises · 1 intro · 5 core · 1 deep · 1 architect

- **branch-commit-merge** *(intro)* — the loop, done properly once.
  *Check:* a feature branch is merged with its history intact, and the answer
  states what the merge commit records that a fast-forward does not.
  *Source:* roadmap.sh.

- **bisect-the-regression** *(core)* — 200 commits, one broke checkout totals.
  *First guess:* read the diff of the suspicious-looking commit.
  *Check:* the correct commit hash, found with an automated `git bisect run`.
  *Source:* roadmap.sh.

- **rebase-or-merge** *(core)* — a conflict resolved two ways, one of which loses a fix.
  *First guess:* accept theirs and move on.
  *Check:* the resulting tree contains both changes and the test suite passes.
  *Source:* own.

- **secret-in-history** *(deep)* — a token committed three weeks ago.
  *First guess:* `git rm` the file and push.
  *Check:* the value is absent from every reachable object *and* the answer file
  records the rotation — history rewriting alone fails the check.
  *Source:* own; pairs with module 12's leaked-secret.

- **reflog-recovery** *(core)* — `reset --hard` on the wrong branch.
  *First guess:* re-clone and redo the work.
  *Check:* the lost commits are back with their original hashes.
  *Source:* own.

- **large-files-and-lfs** *(core)* — the clone takes nine minutes.
  *First guess:* delete the file in a new commit; the objects stay.
  *Check:* fresh-clone size under target with the asset still available via LFS.
  *Source:* roadmap.sh.

- **submodule-detached** *(core)* — CI builds an old version of a vendored library.
  *First guess:* `git pull` in the submodule.
  *Check:* the parent records the intended commit and a clean clone builds it.
  *Source:* own.

- **hooks-that-catch-it-earlier** *(architect)* — the same secret, stopped before the push.
  *First guess:* trust everyone to remember.
  *Check:* the hook blocks the bad commit and permits the good one, with no
  false positive on the fixture repo; the written rationale must address what
  happens when someone uses `--no-verify`.
  *Source:* own.

---

## 09 — Containers
`none` (scratch workspace) · 12 exercises · 3 shipped · 1 intro · 8 core · 3 deep

- **build-run-inspect** *(intro)* — build an image, run it, and find the file you
  wrote after the container exits.
  *Check:* the image builds and runs, and the answer states where the written
  file went and why the next `docker run` cannot see it.
  *Source:* own; the container-is-not-a-VM moment, before anything is broken.

- **pid1-signals** *(core · shipped)* — `docker stop` always takes ten seconds.
  *First guess:* raise the stop timeout.
  *Check:* clean shutdown well under the grace period, handler observed running.
  *Source:* own.

- **layer-cache-and-size** *(core · shipped)* — 1158 MB image, every commit rebuilds.
  *First guess:* `--squash` or a smaller base alone.
  *Check:* image under 250 MB and a source-only change hits the cache.
  *Source:* own.

- **compose-networking** *(core · shipped)* — API cannot reach Redis, both healthy.
  *First guess:* publish more ports.
  *Check:* `/health` green via service DNS, not via published ports.
  *Source:* own.

- **uid-mismatch-on-a-volume** *(core)* — the container writes as root; the host cannot read.
  *First guess:* `chmod -R 777` the volume.
  *Check:* files owned by the intended non-root uid, container still able to write.
  *Source:* own.

- **secrets-in-layers** *(deep)* — the build arg is in `docker history`.
  *First guess:* delete the file in a later layer.
  *Check:* the value appears in no layer of the final image; build still works.
  *Source:* own.

- **dockerignore-and-context** *(core)* — a 40-second build spends 30 sending context.
  *First guess:* faster network.
  *Check:* context under target and the image still contains everything it runs.
  *Source:* own.

- **healthcheck-semantics** *(core)* — the container is `unhealthy` and still serving.
  *First guess:* remove the health check.
  *Check:* the check reflects readiness, and compose `--wait` blocks correctly on it.
  *Source:* own.

- **exec-format-error** *(core)* — the image runs on the laptop and not on the runner.
  *First guess:* rebuild it; same result.
  *Check:* a manifest that satisfies both architectures, verified by inspection.
  *Source:* own.

- **memory-limit-and-oom** *(deep)* — the container dies at exactly the same input size.
  *First guess:* the app leaks.
  *Check:* correct limit *and* correct in-container heap setting; the same input
  now completes.
  *Source:* own; pairs with 01's oom-killed.

- **logs-that-fill-the-disk** *(core)* — a healthy service takes the host down in a week.
  *First guess:* delete the log file the container holds open.
  *Check:* bounded log growth under a sustained write, driver configured.
  *Source:* own; callback to disk-full-triage.

- **rootless-and-capabilities** *(deep)* — the container needs one privileged thing.
  *First guess:* `--privileged`.
  *Check:* the workload runs with the single capability it needs and fails a
  privilege-escalation probe.
  *Source:* roadmap.sh security basics.

---

## 10 — Databases & Data Stores
`db-stack` (new) · 14 exercises · 2 intro · 5 core · 6 deep · 1 architect

The gap this course had. Postgres appeared in modules 22 and 23 only as
something to fail over and restore — never as something to *operate*. A DevOps
engineer who cannot read a query plan or recognise autovacuum starvation is
carrying a pager for a system they cannot debug.

`db-stack`: Postgres primary and replica, pgbouncer, Redis, a seeded 10M-row
`orders` table, `pg_stat_statements` enabled.

- **connect-and-grant** *(intro)* — the application user can drop every table.
  *Check:* the app works with a role that can read and write its own tables and
  nothing else; a seeded `DROP TABLE` attempt is denied and the denial recorded.
  *Source:* own.

- **read-the-plan** *(intro)* — one query, 10M rows, eleven seconds.
  *Check:* the answer quotes the scan type, the estimated versus actual row
  counts, and the point in the plan where the estimate went wrong.
  *Source:* own.

- **the-index-that-is-not-used** *(core)* — the index exists and the planner
  ignores it.
  *First guess:* the planner is wrong; force it with a hint.
  *Check:* the query uses the index and returns in budget, with the answer naming
  the cause — an implicit cast, or a function wrapped around the column —
  rebuilding or re-analysing the index alone does not pass.
  *Source:* own.

- **n-plus-one** *(core)* — the page takes four seconds and every query in the log
  is under a millisecond.
  *First guess:* sort the slow-query log by duration; nothing is slow.
  *Check:* the offending statement is identified by `calls` in
  `pg_stat_statements`, and the page loads in budget after the fix.
  *Source:* own.

- **lock-contention** *(core)* — a migration has been "running" for 40 minutes and
  the whole queue is behind it.
  *First guess:* cancel and retry the migration.
  *Check:* the blocking transaction is identified from `pg_locks` and
  `pg_stat_activity`, the queue drains, and the answer names why the migration
  waited on a session that was idle in transaction.
  *Source:* own.

- **replication-lag-stale-read** *(core)* — the write succeeded and the next read
  cannot find it.
  *First guess:* the write did not commit; retry it.
  *Check:* lag is quantified from the replication position, and the read-your-
  writes case is correct afterwards — routing every read to the primary fails the
  check, because it defeats the replica's purpose.
  *Source:* own.

- **redis-eviction-and-persistence** *(core)* — the cache is cold after every
  restart and the job queue lost entries.
  *First guess:* increase `maxmemory`.
  *Check:* the eviction policy is appropriate for each keyspace, queue entries
  survive a restart, and the answer explains why one policy was silently
  discarding data that was never a cache.
  *Source:* own.

- **index-that-costs-more-than-it-saves** *(deep)* — six indexes and write
  throughput has halved.
  *First guess:* more indexes make things faster.
  *Check:* write throughput recovers and every remaining index is justified by a
  query in the workload; dropping the wrong one fails the read-side check.
  *Source:* own.

- **deadlock-detected** *(deep)* — two transactions, one aborted every few minutes.
  *First guess:* catch the error and retry.
  *Check:* the deadlock is gone under the same concurrent workload because the
  lock acquisition order was made consistent — a retry loop still records
  deadlocks and fails.
  *Source:* own.

- **isolation-anomaly** *(deep)* — two concurrent updates and one of them vanishes.
  *First guess:* wrap it in a transaction, which it already is.
  *Check:* the lost update no longer occurs under the same concurrency, and the
  answer states the isolation level involved and the measured cost of the fix
  chosen — row lock versus serializable retry.
  *Source:* own.

- **bloat-and-autovacuum** *(deep)* — the table is four times its data size and
  nothing was inserted.
  *First guess:* run `VACUUM FULL` in production.
  *Check:* bloat back under threshold with the table available throughout, and
  the long-lived transaction that was holding the horizon is identified as the
  cause.
  *Source:* own.

- **xid-wraparound-warning** *(deep)* — a warning in the log that becomes a
  refusal to accept writes.
  *First guess:* ignore it; the database is fine.
  *Check:* the oldest frozen XID age is brought back under threshold and the
  answer explains what would have happened at the limit.
  *Source:* own.

- **zero-downtime-migration** *(deep)* — `ADD COLUMN NOT NULL DEFAULT` on 10M rows
  takes the whole table.
  *First guess:* run it during a quiet period.
  *Check:* the column exists and is populated with the application serving
  throughout, via expand → backfill in bounded batches → contract; a single
  statement that holds an exclusive lock past the budget fails.
  *Source:* own.

- **pick-the-store** *(architect)* — four workloads, four choices.
  *Check:* the answer picks a store per workload and cites the deciding
  constraint — access pattern, consistency requirement, durability, or
  cardinality — graded against a rubric that rejects "it scales better".
  *Source:* own.

---

## 11 — Artifacts & Supply Chain
`ci-stack` (Harbor) · 9 exercises · 1 intro · 5 core · 2 deep · 1 architect

- **push-your-first-image** *(intro)* — tag it, push it, pull it back on another host.
  *Check:* the image is pullable from Harbor by a second client, and the answer
  states what the tag actually names and what the digest names.
  *Source:* own.

- **push-pull-and-mutable-tags** *(core)* — `:latest` changed under a running deploy.
  *First guess:* re-tag and redeploy.
  *Check:* deployment pinned by digest; a re-pushed tag no longer changes what runs.
  *Source:* own.

- **retention-ate-the-rollback** *(core)* — the image you need to roll back to is gone.
  *First guess:* rebuild the old commit; the build is not reproducible.
  *Check:* a retention policy that keeps what the rollback window requires, proven
  by attempting the rollback.
  *Source:* own.

- **cosign-sign-and-verify** *(core)* — an unsigned image reaches staging.
  *First guess:* trust the registry.
  *Check:* signed images deploy, an unsigned or re-tagged one is rejected.
  *Source:* roadmap.sh supply chain.

- **sbom-and-the-cve-gate** *(deep)* — the scanner blocks the build on a CVE in a test dep.
  *First guess:* turn the gate off.
  *Check:* gate passes with a justified, expiring exception and still fails on a
  genuinely exploitable runtime CVE.
  *Source:* own.

- **base-image-by-digest** *(core)* — the build broke and nothing in the repo changed.
  *First guess:* clear the cache.
  *Check:* pinned base by digest; a moved upstream tag no longer changes the build.
  *Source:* own.

- **dependency-confusion** *(deep)* — an internal package name resolves to a public one.
  *First guess:* rename the package.
  *Check:* the resolver prefers the internal mirror and a planted public
  impostor is never installed.
  *Source:* the left-pad and event-stream incidents, generalised.

- **registry-auth** *(core)* — CI can pull, the runtime cannot.
  *First guess:* make the repository public.
  *Check:* a scoped robot account with pull-only rights, verified both ways.
  *Source:* own.

- **incident-eventstream-2018** *(architect · replay)* — a maintainer handoff ships malware.
  *First guess:* pin versions, which this incident defeats.
  *Check:* lockfile plus mirror plus review gate stops the malicious version.
  *Source:* published write-ups, simplified.

---

## 12 — CI/CD
`ci-stack` · 11 exercises · 3 shipped · 1 intro · 8 core · 1 deep · 1 architect

- **run-it-on-every-push** *(intro)* — one workflow, one command, on push.
  *Check:* a push triggers the run and the run reports the command's real exit
  status — the rung below first-pipeline, where nothing is broken yet.
  *Source:* own.

- **first-pipeline** *(core · shipped)* — the run is created and nothing happens.
  *First guess:* the YAML is wrong; it is valid.
  *Check:* the job actually executes on a runner that advertises the label.
  *Source:* own.

- **leaked-secret** *(core · shipped)* — a deploy token hardcoded in the workflow.
  *First guess:* delete the line.
  *Check:* removed from the tree, sourced from a secret, and rotated.
  *Source:* own.

- **green-pipeline** *(core · shipped)* — a month of green builds that ran no tests.
  *First guess:* trust the green tick.
  *Check:* CI runs the suite, goes red on the real bug, and green only once fixed.
  *Source:* own.

- **cache-poisoned-green** *(deep)* — CI passes with a dependency that is not in the lockfile.
  *First guess:* clear the cache manually forever.
  *Check:* cache key includes the lockfile hash; a changed lockfile misses the cache.
  *Source:* own.

- **matrix-and-fail-fast** *(core)* — one shard fails, the report says success.
  *First guess:* read the summary line.
  *Check:* aggregate status reflects every shard, and a flaky shard is retried
  without hiding a real failure.
  *Source:* own.

- **promote-do-not-rebuild** *(core)* — staging and production run different bytes.
  *First guess:* rebuild per environment from the same commit.
  *Check:* one artefact digest travels through every stage.
  *Source:* own.

- **branch-protection-bypass** *(core)* — a change reached main without review.
  *First guess:* add a rule; the path around it is still open.
  *Check:* the bypass route is closed and the emergency path is auditable.
  *Source:* own.

- **deploy-race** *(core)* — two merges deploy simultaneously and the older wins.
  *First guess:* tell people to merge slower.
  *Check:* concurrency group serialises deploys; the newest commit ends up live.
  *Source:* own.

- **jenkinsfile** *(core)* — the same pipeline in the tool the enterprise actually runs.
  *First guess:* freestyle jobs and manual steps.
  *Check:* declarative pipeline reproduces build → test → publish with the same gates.
  *Source:* roadmap.sh (Jenkins is still everywhere).

- **staged-rollout** *(architect)* — a bad change reaches 100% of nodes in 40 seconds.
  *First guess:* faster rollback.
  *Check:* the rollout halts at the canary stage on the failing signal.
  *Source:* Cloudflare 2019, as the delivery-side lesson.

---

## 13 — IaC: OpenTofu
`iac-stack` (new) · 10 exercises · 1 intro · 7 core · 1 deep · 1 architect

- **first-resource** *(intro)* — a container managed by code instead of by hand.
  *First guess:* `docker run` and write the HCL afterwards.
  *Check:* plan/apply/destroy cycle is clean and repeatable from an empty state.
  *Source:* roadmap.sh.

- **what-is-in-state** *(core)* — the file everyone is afraid of.
  *First guess:* edit state by hand.
  *Check:* the resource is corrected through `state mv`/`rm`/`import`, not an editor,
  and a subsequent plan is empty.
  *Source:* own.

- **two-applies-one-lock** *(core)* — a colleague applies while you do.
  *First guess:* retry until it works.
  *Check:* locking enabled and demonstrated; the second apply waits rather than
  corrupting state.
  *Source:* own.

- **drift** *(core)* — someone deleted a resource in the console.
  *First guess:* re-run apply and hope.
  *Check:* drift detected in plan, reconciled, and a detection step added to CI.
  *Source:* roadmap.sh.

- **modules-and-outputs** *(core)* — the same three resources copy-pasted four times.
  *First guess:* copy it a fifth time.
  *Check:* one module, four instances, no duplicated resource blocks, plan stable.
  *Source:* own.

- **import-what-exists** *(core)* — infrastructure that predates the code.
  *First guess:* destroy and recreate in production.
  *Check:* imported with an empty plan afterwards.
  *Source:* own.

- **count-versus-for-each** *(core)* — removing the second item destroys the third.
  *First guess:* it is a provider bug.
  *Check:* keyed addressing; removing an item touches only that item in the plan.
  *Source:* own.

- **remote-backend-on-minio** *(core)* — state on a laptop.
  *First guess:* commit the state file.
  *Check:* remote backend with locking, migrated without losing resources, and the
  state file is gitignored.
  *Source:* own.

- **prevent-destroy** *(architect)* — a plan that would delete the database.
  *First guess:* read the plan carefully every time.
  *Check:* the destructive plan is blocked by policy, and the legitimate change
  still applies.
  *Source:* own.

- **serverless-cold-start** *(deep)* — a function that times out only on the first call.
  *First guess:* raise the timeout to 30 seconds.
  *Check:* cold-start latency measured, timeout justified against it, and the
  initialisation moved out of the request path.
  *Source:* roadmap.sh serverless gap, on floci.

---

## 14 — IaC: Pulumi (Go)
`iac-stack` · 6 exercises · 1 intro · 3 core · 1 deep · 1 architect

- **first-program-in-go** *(intro)* — one resource, in a language with a compiler.
  *Check:* `pulumi up` creates it and `pulumi destroy` removes it, and the answer
  states what the compiler caught that HCL would have failed on at apply time.
  *Source:* own.

- **same-infra-in-go** *(core)* — port the module-13 stack.
  *Check:* both stacks converge on identical resources; plan is empty after port.
  *Source:* own.

- **what-hcl-cannot-say** *(core)* — conditional topology from a config value.
  *First guess:* nested `count` tricks in HCL.
  *Check:* the Go program produces both topologies from one input.
  *Source:* own.

- **stacks-and-secrets** *(core)* — dev and prod from one program.
  *Check:* per-stack config, encrypted secret never present in plaintext in the repo.
  *Source:* own.

- **unit-testing-infrastructure** *(deep)* — a test that fails when the bucket goes public.
  *First guess:* apply and look.
  *Check:* mocks-based test fails on the bad property before anything is created.
  *Source:* Pulumi Go mocks; the capability HCL lacks.

- **when-not-to** *(architect)* — a decision exercise with a written verdict.
  *Check:* the answer file picks a tool per scenario and cites the constraint that
  decided it; graded against a rubric of required factors.
  *Source:* own.

---

## 15 — Config Management: Ansible
`linux-box` · 6 exercises · 1 intro · 5 core

- **inventory-and-ad-hoc** *(intro)* — twelve boxes, one command.
  *Check:* the fact is gathered from every host in the group, none missed.
  *Source:* roadmap.sh.

- **the-playbook** *(core)* — install and configure nginx from nothing.
  *Check:* service serving the expected page after a single run on a clean box.
  *Source:* own.

- **idempotency** *(core)* — the second run reports six changes.
  *First guess:* it is fine, the result is the same.
  *Check:* `changed=0` on the second run, with the same end state.
  *Source:* roadmap.sh; the property that separates config management from scripts.

- **handlers-that-never-fire** *(core)* — config changes, service keeps old settings.
  *First guess:* always restart the service.
  *Check:* handler fires on change only, and the running config matches the file.
  *Source:* own.

- **roles-and-molecule** *(core)* — the playbook nobody can reuse.
  *Check:* role passes a molecule scenario from a clean container.
  *Source:* own.

- **vault-and-become** *(core)* — a password in `group_vars`.
  *Check:* encrypted at rest, decryptable in the run, absent from plaintext in git.
  *Source:* own.

---

## 16 — Secrets
`ci-stack` (OpenBao) · 7 exercises · 1 intro · 4 core · 2 deep

- **store-and-read** *(intro)* — put a secret in, get it out of an application.
  *Check:* the app reads the value from OpenBao at runtime, and the value appears
  in no file, no image layer and no environment dump collected by the check.
  *Source:* own.

- **kv-and-least-privilege** *(core)* — one token that can read everything.
  *Check:* per-service policy; the wrong path is denied and proven denied.
  *Source:* own.

- **dynamic-database-credentials** *(deep)* — a shared password in four services.
  *First guess:* rotate it manually every quarter.
  *Check:* each service gets a leased credential; revoking a lease kills exactly
  one service's access.
  *Source:* own.

- **sops-and-age** *(core)* — encrypted files in git that CI can still read.
  *Check:* ciphertext in the repo, plaintext never; CI decrypts with its own key.
  *Source:* own.

- **secret-sprawl-audit** *(core)* — find every secret in a small estate.
  *Check:* the answer file enumerates the planted secrets, including the two that
  are not in obvious places, with no false positives.
  *Source:* own.

- **rotation-without-downtime** *(deep)* — rotating the credential drops requests.
  *First guess:* rotate at 3 a.m. and hope.
  *Check:* dual-read window; a rotation during load causes zero failed requests.
  *Source:* own.

- **what-a-leak-costs** *(core)* — the token from module 12, replayed.
  *Check:* revocation is verified from the attacker's side, not just rotated.
  *Source:* own.

---

## 17 — Cloud Fundamentals & IAM
`iac-stack` (floci) · 10 exercises · 1 intro · 7 core · 1 deep · 1 architect

floci emulates the AWS API locally, so identity, network and storage
misconfiguration — the three that cause the breaches — are reachable without an
account or a bill. Concepts are AWS-shaped because the vocabulary is; the
failures transfer to any provider.

- **identity-not-keys** *(intro)* — a static access key pair in the repository.
  *Check:* the workload authenticates with an assumed role and no long-lived key
  exists anywhere in the tree or the environment.
  *Source:* own.

- **policy-least-privilege** *(core)* — the policy is `Action: "*"` on `Resource: "*"`.
  *First guess:* narrow it until something breaks, then widen it back.
  *Check:* the application's real operations succeed, a seeded probe of three
  adjacent actions is denied, and no wildcard remains on either field.
  *Source:* roadmap.sh cloud fundamentals.

- **assume-role-across-accounts** *(core)* — the trust policy trusts everyone.
  *First guess:* the permission policy is what matters.
  *Check:* the intended principal can assume the role, an unintended one cannot,
  and the answer names which of the two policies did the work.
  *Source:* own.

- **public-bucket** *(core)* — an object is world-readable through a path nobody audited.
  *First guess:* remove the public ACL on the object.
  *Check:* the object is private by every route — ACL, bucket policy, and account
  setting — and the application still reads it.
  *Source:* own; the most repeated cloud breach there is.

- **presigned-not-public** *(core)* — a customer needs one file.
  *First guess:* make the bucket public for an afternoon.
  *Check:* the customer's link works, expires at the stated time, and the bucket
  is never public — an expired link is verified to fail.
  *Source:* own.

- **sg-versus-nacl** *(core)* — the security group allows it and the traffic still dies.
  *First guess:* widen the security group further.
  *Check:* traffic flows, and the answer names why the stateless rule dropped the
  return packet while the stateful one did not.
  *Source:* own.

- **private-subnet-egress** *(core)* — the instance must reach the internet and
  must not be reachable from it.
  *First guess:* give it a public address and a restrictive security group.
  *Check:* outbound works, inbound from outside fails, and the route table shows
  the traffic leaving by the gateway the design requires.
  *Source:* own.

- **lifecycle-and-versioning** *(core)* — the deleted object is still billed, and
  the one you needed is gone.
  *First guess:* deletion frees the storage.
  *Check:* the needed version is recovered, and a lifecycle rule bounds the cost
  of noncurrent versions without breaking the recovery window.
  *Source:* own.

- **cost-surprise** *(deep)* — the bill went up $2,000 and nothing was deployed.
  *First guess:* the biggest instance is the cause; it is not.
  *Check:* the three contributors are identified from the seeded billing and
  resource data — unattached volumes, cross-zone egress, and an untagged resource
  with no owner — with the saving quantified for each.
  *Source:* own.

- **managed-versus-self** *(architect)* — four services, buy or build.
  *Check:* each decision names what the managed option actually removes from the
  on-call rotation and what it adds in lock-in or cost, graded against a rubric
  that rejects an answer with no stated downside.
  *Source:* own.

---

## 18 — Metrics
`obs-stack` (new) · 10 exercises · 1 intro · 7 core · 2 deep

- **target-down** *(intro)* — a scrape target that is up but not scraped.
  *First guess:* restart Prometheus.
  *Check:* the target reports `up == 1` for the right reason (network/relabel/port).
  *Source:* own.

- **instrument-red** *(core)* — a service with no metrics of its own.
  *Check:* rate, errors and duration exposed and queryable, histogram buckets sane.
  *Source:* own.

- **exporter-you-write** *(core)* — the thing you need to measure has no exporter.
  *First guess:* scrape the log file.
  *Check:* the exporter serves valid metrics with correct types and help text,
  survives the scrape interval under load, and reports zero rather than
  disappearing when the source is unavailable.
  *Source:* own.

- **use-for-a-node** *(core)* — saturation that no CPU graph shows.
  *Check:* the saturating resource is identified from utilisation/saturation/errors.
  *Source:* Brendan Gregg's USE method.

- **alert-that-pages-correctly** *(core)* — an alert that fires and reaches nobody.
  *Check:* route, grouping and inhibition deliver exactly one notification for a
  correlated outage.
  *Source:* own.

- **dashboard-that-answers-a-question** *(core)* — a wall of 40 panels nobody reads.
  *First guess:* add more panels.
  *Check:* the dashboard answers the three stated questions within the deadline,
  with templated variables working across environments — and a panel that answers
  none of the three must be gone.
  *Source:* own.

- **cardinality-explosion** *(deep)* — Prometheus memory triples after a deploy.
  *First guess:* give it more memory.
  *Check:* series count back under budget with the same question still answerable.
  *Source:* own; the most common self-inflicted observability wound.

- **rate-versus-increase** *(core)* — a counter reset makes a graph lie.
  *Check:* the query survives a restart of the exporter and still reports truth.
  *Source:* own.

- **recording-rules** *(core)* — a dashboard that times out.
  *Check:* panel loads under the deadline; the rule's output matches the raw query.
  *Source:* own.

- **absent-and-staleness** *(deep)* — the alert that did not fire because the data stopped.
  *First guess:* thresholds only.
  *Check:* missing data pages; a normal deploy gap does not.
  *Source:* own.

---

## 19 — Logs & Traces
`obs-stack` · 9 exercises · 1 intro · 5 core · 3 deep

- **ship-one-log-line** *(intro)* — get a single application log line into Loki
  and find it again by query.
  *Check:* the line is queryable by its label set, and the answer states which
  part of the record became a label and which stayed in the line.
  *Source:* own.

- **collector-pipeline** *(core)* — receivers, processors, exporters, in the right order.
  *Check:* a signal makes it end to end with the expected attributes.
  *Source:* own.

- **ottl-transform** *(core)* — one field needs to become three.
  *Check:* transformed records match the target schema; malformed input is dropped
  rather than crashing the pipeline.
  *Source:* own.

- **vrl-redact-pii** *(core)* — customer emails are in the logs.
  *First guess:* a regex that also eats the order ids.
  *Check:* PII gone, everything else intact, verified field by field.
  *Source:* own.

- **loki-labels** *(deep)* — a query that scans everything.
  *First guess:* add a label for request id.
  *Check:* label cardinality bounded and the same query returns in budget.
  *Source:* own.

- **mapping-explosion** *(deep)* — an OpenSearch index that will not accept new documents.
  *Check:* explicit mapping, bounded fields, ingest resumes without data loss.
  *Source:* own.

- **broken-trace** *(core)* — the trace stops at a queue boundary.
  *First guess:* the tracer is misconfigured.
  *Check:* context propagated across the async hop; one trace spans all three services.
  *Source:* own.

- **exemplars** *(core)* — a p99 you cannot explain.
  *Check:* the metric links to a trace that demonstrates the slow path.
  *Source:* own.

- **the-four-percent** *(deep)* — the pipeline silently drops 4% of logs.
  *First guess:* the application stopped logging.
  *Check:* the drop is located (queue/batch/backpressure), fixed, and a metric now
  alerts on it.
  *Source:* own.

---

## 20 — Performance, Percentiles & Scalability
`obs-stack` + `chaos-stack` · 15 exercises · 1 intro · 6 core · 6 deep · 2 architect

- **read-a-percentile** *(intro)* — 1,000 request durations, computed by hand,
  then by query.
  *Check:* the hand-computed p50, p95 and p99 match the query's answers, and the
  answer states how many of the 1,000 requests are worse than the p99.
  *Source:* own; the arithmetic before the argument.

- **the-average-lies** *(core)* — a healthy mean over a broken service.
  *Check:* the answer identifies the affected user share from the distribution.
  *Source:* own.

- **histograms-versus-summaries** *(deep)* — averaging a quantile across instances.
  *First guess:* `avg(p99)`.
  *Check:* correct aggregate computed from histogram buckets; the wrong method's
  error is quantified in the answer.
  *Source:* own.

- **coordinated-omission** *(deep)* — the load generator hides the worst latency.
  *First guess:* the p99 in the report is the p99.
  *Check:* open-model measurement reveals the true tail; both numbers reported.
  *Source:* Gil Tene's argument, made hands-on with k6.

- **load-test-shapes** *(core)* — the same service under five different tests.
  *First guess:* one ramp test tells you everything.
  *Check:* ramp, soak, spike, stress and breakpoint each run, and the answer names
  which failure only one of them exposed — the soak-only leak is seeded.
  *Source:* own.

- **k6-thresholds-as-a-gate** *(core)* — a load test that always passes.
  *First guess:* eyeball the summary output.
  *Check:* thresholds fail the run on the seeded regression and pass the healthy
  build, with the process exit code driving the pipeline.
  *Source:* own.

- **fan-out-amplification** *(deep)* — a fast backend that produces a slow page.
  *Check:* the arithmetic is demonstrated and the fix (parallel/hedged/cached)
  brings the page p99 under budget.
  *Source:* own.

- **littles-law** *(core)* — how many workers do you actually need.
  *Check:* the computed number is validated by a run at that concurrency.
  *Source:* own.

- **the-knee** *(deep)* — the ninth node makes it slower.
  *First guess:* scale out further.
  *Check:* the contention point is identified and throughput improves without
  adding nodes.
  *Source:* own.

- **usl-and-the-second-coefficient** *(architect)* — fit the curve, then predict.
  *Check:* contention and coherency coefficients are fitted from the measured
  throughput series, the predicted peak matches a held-out run within tolerance,
  and the answer states what the model cannot tell you.
  *Source:* the Universal Scalability Law, made measurable.

- **pool-sizing** *(core)* — more connections, less throughput.
  *Check:* pgbouncer sized from measurement; p99 improves and errors go to zero.
  *Source:* own; pairs with module 10.

- **cache-stampede** *(deep)* — one expiry takes the database down.
  *First guess:* longer TTL.
  *Check:* single-flight or jittered TTL; origin load stays bounded at expiry.
  *Source:* own.

- **flame-graph** *(deep)* — 30% of CPU in a function nobody suspected.
  *Check:* the hot path is named from the profile and the fix is measured.
  *Source:* Brendan Gregg.

- **benchmark-traps** *(core)* — the same code, three different numbers.
  *Check:* warm-up, cache state and noisy neighbours controlled; results repeatable
  within tolerance.
  *Source:* own.

- **cpu-over-eighty** *(architect)* — a bad alert replaced by a good one.
  *Check:* the new alert fires on user-visible harm and stays quiet through a
  harmless CPU spike.
  *Source:* own.

---

## 21 — Failure Handling & Resilience Patterns
`chaos-stack` · 13 exercises · 1 shipped · 1 intro · 8 core · 2 deep · 2 architect

- **set-a-timeout** *(intro)* — the one-line change, before any of the patterns.
  *Check:* the client gives up within the stated budget instead of waiting
  forever, and the answer names the two different timeouts involved — connect
  and read — and which one the seeded fault exercised.
  *Source:* own; the rung below no-timeout-hangs.

- **no-timeout-hangs** *(core · shipped)* — a slow dependency fills the worker pool.
  *First guess:* restart checkout.
  *Check:* bounded wait; the page that does not need pricing keeps serving.
  *Source:* own.

- **retry-storm** *(core)* — the retry that turns a blip into an outage.
  *First guess:* retry harder.
  *Check:* upstream request rate stays bounded during the fault window.
  *Source:* own.

- **backoff-and-jitter** *(core)* — synchronised retries from 200 clients.
  *Check:* request arrivals are spread; recovery time drops measurably.
  *Source:* own.

- **circuit-breaker** *(core)* — failing fast beats failing slowly.
  *Check:* breaker opens under sustained failure, half-opens, and closes on
  recovery — all three transitions observed.
  *Source:* own.

- **pool-exhaustion** *(core)* — one slow endpoint starves every other endpoint.
  *Check:* bulkheads or per-route pools keep the healthy routes serving.
  *Source:* own.

- **idempotency-keys** *(core)* — at-least-once delivery charges twice.
  *First guess:* deduplicate in the client.
  *Check:* replayed requests produce exactly one side effect.
  *Source:* own.

- **dead-letter-queue** *(core)* — one poison message stops the queue.
  *Check:* the bad message is isolated, the queue drains, and nothing is lost.
  *Source:* own.

- **graceful-shutdown** *(core)* — a deploy drops in-flight requests.
  *First guess:* longer grace period.
  *Check:* zero failed requests through a rolling restart under load.
  *Source:* own.

- **load-shedding** *(deep)* — degrading on purpose beats collapsing by accident.
  *Check:* under 3× capacity, the service sheds the excess and keeps p99 for the rest.
  *Source:* own.

- **cascading-failure** *(deep)* — one slow dependency takes down three healthy services.
  *Check:* the blast radius is contained; the unrelated services stay up.
  *Source:* own.

- **incident-knight-capital-2012** *(architect · replay)* — a deploy to seven of
  eight hosts, and a flag that meant something else on the eighth.
  *Check:* the reconstruction shows the divergence, and the fix makes a partial
  deploy detectable before it trades.
  *Source:* published SEC filing and analyses, heavily simplified.

- **incident-aws-s3-2017** *(architect · replay)* — a typo in a runbook command
  removes more capacity than intended, and the systems that would have told you
  depended on the thing that was down.
  *First guess:* the fix is to be more careful when typing.
  *Check:* the circular dependency is identified and broken — the status signal
  survives the failure of what it reports on — and the capacity-removal path is
  bounded so a single command cannot exceed the blast radius.
  *Source:* published AWS postmortem, simplified.

---

## 22 — High Availability
`ha-stack` (new) · 11 exercises · 1 intro · 6 core · 2 deep · 2 architect

- **two-nodes-one-name** *(intro)* — put a load balancer in front of two servers.
  *Check:* both backends receive traffic under a spread of requests, and stopping
  either one leaves the service answering — the baseline every later exercise in
  this module breaks.
  *Source:* own.

- **hunt-the-spof** *(core)* — draw the topology, then break each box.
  *Check:* the answer file lists every single point of failure; the grader kills
  each one and compares.
  *Source:* own.

- **vip-failover** *(core)* — keepalived, and the four seconds nobody measured.
  *Check:* failover completes within the stated budget with no split VIP.
  *Source:* own.

- **active-active** *(core)* — two nodes, one session store.
  *First guess:* sticky sessions solve it.
  *Check:* a request served by either node sees the same session; killing one
  node loses no session.
  *Source:* own.

- **the-lying-health-check** *(core · callback)* — 200 while the database is down.
  *Check:* the node leaves rotation on dependency failure and rejoins on recovery.
  *Source:* own; callback to module 06.

- **replica-promotion** *(core)* — the primary is gone; the replica is read-only.
  *Check:* promoted replica accepts writes, the application follows, and no
  committed transaction is lost.
  *Source:* own; builds on module 10's replication-lag-stale-read.

- **split-brain** *(deep)* — three-node etcd, kill two.
  *First guess:* force the survivor to accept writes.
  *Check:* the cluster refuses to lose quorum, and recovery restores consistency
  without data divergence.
  *Source:* own.

- **leader-election** *(core)* — two schedulers both think they lead.
  *Check:* exactly one leader across a partition and a restart.
  *Source:* own.

- **serve-stale** *(deep)* — degrade instead of 500.
  *Check:* with the backend down, users get stale-but-labelled content and the
  error budget is spent slowly rather than instantly.
  *Source:* own.

- **incident-github-2018** *(architect · replay)* — 43 seconds of partition,
  24 hours of reconciliation.
  *Check:* the reconstruction demonstrates why failing back was harder than
  failing over; the runbook produced is graded against required steps.
  *Source:* published GitHub postmortem, simplified.

- **incident-facebook-bgp-2021** *(architect · replay)* — a routing withdrawal
  that removes the network the operators needed to reach the network.
  *First guess:* roll back the change — the path to roll it back is gone.
  *Check:* the reconstruction identifies every dependency that had to survive
  the outage to permit recovery, and the out-of-band access path the student
  designs is proven by exercising it while the primary path is withdrawn.
  *Source:* published Facebook postmortem, simplified.

---

## 23 — Backup & Disaster Recovery
`ha-stack` · 10 exercises · 1 intro · 4 core · 2 deep · 3 architect

- **take-a-backup** *(intro)* — run the dump, then open it.
  *Check:* the backup file exists and the answer states which of the three named
  tables it actually contains — the dump was taken with a flag that excluded one,
  and reading the file is the only way to find out.
  *Source:* own; the rung below backup-then-restore.

- **rpo-and-rto-first** *(architect)* — numbers before design.
  *Check:* the stated objectives are consistent with the design that follows;
  a design that cannot meet them fails.
  *Source:* own.

- **backup-then-restore** *(core)* — the backup nobody has restored.
  *First guess:* the dump exited 0, so it worked.
  *Check:* a restore into a clean instance reproduces the data exactly.
  *Source:* own.

- **pitr** *(deep)* — recover to the moment before the bad `DELETE`.
  *Check:* the target timestamp is hit; the row count matches the pre-incident state.
  *Source:* own.

- **restore-under-a-timer** *(core)* — measure the real RTO.
  *Check:* wall-clock restore time recorded and compared against the promise; the
  answer must reconcile the gap.
  *Source:* own.

- **lost-state-file** *(core)* — the OpenTofu state is gone.
  *First guess:* apply again and create everything twice.
  *Check:* infrastructure re-adopted by import; plan empty, nothing recreated.
  *Source:* own.

- **lost-unseal-keys** *(core)* — OpenBao sealed, keys unavailable.
  *Check:* the documented recovery path is followed, or the honest conclusion is
  reached and the rebuild is executed.
  *Source:* own.

- **3-2-1-and-immutable** *(deep)* — the ransomware angle.
  *Check:* a backup copy survives an attacker with production credentials.
  *Source:* own.

- **region-loss-tabletop** *(architect)* — the whole region is gone for six hours.
  *Check:* the written plan meets the module's stated RPO and RTO using only
  resources that exist outside the lost region, names the decision owner for the
  failover call, and is graded against a rubric that rejects any step depending
  on something inside the failed region.
  *Source:* own.

- **incident-gitlab-2017** *(architect · replay)* — five backup methods, none working.
  *Check:* each planted failure mode is detected by a verification job the student
  writes, before it is needed.
  *Source:* published GitLab postmortem, simplified.

---

## 24 — SRE Practice & Progressive Delivery
`ha-stack` + `obs-stack` · 13 exercises · 6 core · 2 deep · 5 architect

- **pick-an-sli** *(core)* — three candidate indicators, one correlates with pain.
  *Check:* the chosen SLI moves during the seeded incident and stays flat during
  the seeded non-incident.
  *Source:* Google SRE Workbook.

- **slo-and-error-budget** *(core)* — the maths, on real numbers.
  *Check:* budget computed correctly and burn during the incident matches.
  *Source:* Google SRE Workbook.

- **multi-burn-rate-alerts** *(deep)* — page for the fast burn, ticket for the slow one.
  *Check:* fast burn pages within minutes; slow burn does not page; a blip does
  neither.
  *Source:* Google SRE Workbook.

- **golden-use-red** *(core)* — the same service, three framings.
  *Check:* each framing answers the question it is good at; the mismatch is named.
  *Source:* own.

- **kill-the-toil** *(core)* — a weekly manual task.
  *Check:* automated, measured, and the time saved is demonstrated by a second run.
  *Source:* Google SRE Workbook.

- **canary-with-analysis** *(deep)* — a bad build that passes CI.
  *Check:* automated analysis rejects the canary on the metric that moved.
  *Source:* own.

- **blue-green-and-rollback** *(core)* — roll back in under a minute.
  *Check:* traffic returns to the good version within the budget; database
  compatibility is preserved both directions.
  *Source:* own; the database half builds on module 10's zero-downtime-migration.

- **feature-flag-kill-switch** *(core)* — turn it off without a deploy.
  *Check:* the flag disables the path in seconds and the stale-flag audit is clean.
  *Source:* own.

- **incident-command** *(architect)* — an incident with three people and no structure.
  *Check:* roles are assigned and held, the severity call matches the published
  criteria, status updates land at the stated cadence, and the answer is graded
  against a rubric that rejects a commander who also debugs.
  *Source:* own.

- **capacity-planning** *(architect)* — the growth forecast and the Little's Law
  numbers from module 20.
  *Check:* the plan states the headroom target, derives instance counts from
  measured service time rather than a guess, and identifies which resource
  saturates first — a plan that scales the wrong dimension fails.
  *Source:* Google SRE Workbook; builds on module 20.

- **error-budget-policy** *(architect)* — the budget is spent in week two.
  *Check:* the written policy states what stops, who decides, and what unblocks
  it, and is graded against a rubric requiring a consequence that is actually
  enforceable by the team that wrote it.
  *Source:* Google SRE Workbook.

- **chaos-done-properly** *(architect)* — hypothesis, blast radius, experiment, conclusion.
  *Check:* the experiment is bounded, the hypothesis is falsifiable, and the
  written conclusion matches what the data showed.
  *Source:* own.

- **the-postmortem** *(architect)* — for the incident you caused in module 21.
  *Check:* timeline, contributing factors, and action items with owners; graded
  against a rubric that rejects blame language and unowned actions.
  *Source:* Google SRE Workbook.

---

## 25 — DORA & Delivery Measurement
`ci-stack` + `obs-stack` · 7 exercises · 1 intro · 3 core · 1 deep · 2 architect

- **count-your-deploys** *(intro)* — how often does this repository actually ship?
  *Check:* the deployment count over the seeded history is correct, and the answer
  states what was counted as a deployment and what was excluded.
  *Source:* DORA 2025.

- **emit-the-events** *(core)* — a pipeline that measures itself.
  *Check:* deployment events recorded with commit and timestamp for every deploy.
  *Source:* own.

- **lead-time** *(core)* — from commit to production, honestly.
  *Check:* computed distribution matches the seeded history; the median is not
  reported as the whole story.
  *Source:* DORA 2025.

- **change-failure-and-fdrt** *(core)* — the 2025 definitions.
  *First guess:* count every incident, including the datacentre outage.
  *Check:* only change-caused failures count toward Failed Deployment Recovery
  Time; the infrastructure incident is correctly excluded.
  *Source:* DORA 2025.

- **rework-rate** *(deep)* — the metric most teams fail.
  *Check:* rework identified from the commit history under the published definition.
  *Source:* DORA 2025.

- **gaming-the-numbers** *(architect)* — four keys that improved while delivery got worse.
  *Check:* the gamed metric is identified and the counter-signal proposed.
  *Source:* own.

- **archetypes** *(architect)* — where does this team actually sit.
  *Check:* the mapping is justified against the seeded data, not vibes.
  *Source:* DORA 2025.

---

## 26 — Platform Engineering
`ci-stack` + `obs-stack` · 9 exercises · 5 core · 3 deep · 1 architect

The discipline the roadmap names and no exercise set teaches: making the right
thing the easy thing for teams who do not report to you, and measuring whether
they actually took it.

- **golden-path-template** *(core)* — a new service takes three days of copying
  from an existing one.
  *First guess:* write a README explaining the steps.
  *Check:* generating from the template produces a service with a working
  pipeline, a dashboard and an alert, all green, with no manual step in between.
  *Source:* own.

- **paved-road-guardrail** *(core)* — the misconfiguration that reached production
  twice.
  *First guess:* add it to the review checklist.
  *Check:* policy-as-code rejects the bad configuration in CI, permits the
  documented exception with an expiry, and the exception's expiry is enforced.
  *Source:* own.

- **self-service-with-a-budget** *(core)* — 40 preview environments and 6 in use.
  *First guess:* ask people to clean up after themselves.
  *Check:* environments are created on demand and reclaimed automatically at the
  stated TTL, with an extension path that requires a reason and does not require
  the platform team.
  *Source:* own.

- **ownership-metadata** *(core)* — an alert fires and nobody knows whose it is.
  *First guess:* a spreadsheet of owners.
  *Check:* the alert routes to the owning team from metadata that lives with the
  service, and a service with no owner fails the pipeline rather than shipping.
  *Source:* own.

- **deprecate-a-paved-road** *(core)* — v1 of the template has a flaw and 30
  services use it.
  *First guess:* announce the deprecation and set a date.
  *Check:* every consumer is migrated, the check proves none remain on v1, and
  the migration path was executed without a coordinated downtime window.
  *Source:* own.

- **platform-slo** *(deep)* — the platform is "up" and nobody can ship.
  *First guess:* measure CI uptime.
  *Check:* the SLI reflects a developer completing the journey the platform
  exists for, moves during the seeded degradation that leaves every component
  technically healthy, and the error budget is computed against it.
  *Source:* own; module 24's method turned on the platform itself.

- **adoption-not-mandate** *(deep)* — two teams route around the golden path.
  *First guess:* mandate it.
  *Check:* the reason is identified from the usage and pipeline data rather than
  asserted, and the change made to the path is validated by those teams adopting
  it without being told to.
  *Source:* own.

- **noisy-neighbour** *(deep)* — one team's build queue starves everyone else's.
  *First guess:* add runners.
  *Check:* per-tenant throughput stays within its share under a seeded burst,
  the heavy tenant still completes, and the answer names the isolation mechanism
  chosen over the two rejected.
  *Source:* own.

- **platform-as-a-product** *(architect)* — a roadmap from the data.
  *Check:* the plan is derived from the adoption, toil and platform-SLO data
  rather than from requests, states what will be said no to, and is graded
  against a rubric requiring a measurable success criterion per item.
  *Source:* own.

---

## 27 — Capstone
all stacks · 4 stages

- **stage-1-ship-it** *(core)* — commit to production through the whole pipeline.
- **stage-2-break-it** *(deep)* — a fault injected at a layer you are not told.
- **stage-3-hold-the-line** *(deep)* — p99 and the SLO survive the experiment.
- **stage-4-write-it-up** *(architect)* — postmortem and runbook, graded against
  the rubric.

Each stage's check is the composition of earlier modules' checks: nothing new is
taught, and nothing already taught may be skipped.

---

## 28 — Handoffs

Not exercises. Pointers to [kubelings](https://github.com/madhank93/kubelings),
[golings](https://github.com/madhank93/golings) and
[learn-cks](https://github.com/madhank93/learn-cks).

---

## Sandboxes this inventory requires

| Stack | State | Serves |
|---|---|---|
| `linux-box` | built | 01, 02, 15 |
| `linux-box` (privileged profile) | **to build** | 03, 07 — loop devices, `SYS_ADMIN`, AppArmor, auditd |
| `none` (scratch) | built | 08, 09 |
| `ci-stack` | built | 11, 12, 16, 25, 26 |
| `chaos-stack` | built | 20, 21 |
| `netlab` | **to build** | 04, 05 — two hosts, a resolver, an MTA, controllable nftables, a second network |
| `web-stack` | **to build** | 06 — nginx, Caddy, two upstreams, a cache |
| `db-stack` | **to build** | 10 — Postgres primary/replica, pgbouncer, Redis, a seeded 10M-row table |
| `iac-stack` | **to build** | 13, 14, 17 — MinIO, floci, docker provider target |
| `obs-stack` | **to build** | 18, 19, 20, 24, 25, 26 — Prometheus, Grafana, Loki, Tempo, OTel, Vector |
| `ha-stack` | **to build** | 22, 23, 24 — HAProxy, keepalived, Postgres primary/replica, etcd |

`db-stack` and `ha-stack` both run Postgres. They stay separate: `db-stack` is
about operating one database, `ha-stack` is about surviving the loss of one, and
merging them would make every module-10 lesson wait on a replication topology it
does not need.

## Build order

Each wave is a shippable slice: sandbox, then its exercises, each passing the
contract test before the next starts.

1. **Finish 01** — permissions-triage and blocked-on-a-pipe, then the four
   remaining additions and the four intro entries. No new sandbox; highest value
   per hour, and the intro rung makes the repo usable by people it currently
   turns away.
2. **02 Scripting** — `linux-box`, no new sandbox, and every later module's
   solutions get better for it.
3. **netlab + 04, 05** — two modules on one new sandbox; the layer everything
   else assumes and nothing teaches hands-on.
4. **db-stack + 10** — the largest role gap. Depends on nothing, so it can run
   in parallel with any other wave.
5. **03 + 07** — one privileged `linux-box` profile serves both.
6. **09 additions + 08** — no new sandbox.
7. **web-stack + 06**.
8. **12 additions + 11** — reuses `ci-stack`; supply chain rides on Harbor.
9. **obs-stack + 18, 19** — the biggest single build; unblocks 20, 24, 25, 26.
10. **20 + 21 additions** — `chaos-stack` and `obs-stack` together; the repo's core.
11. **iac-stack + 13, 14, 16, 15, 17**.
12. **ha-stack + 22, 23**.
13. **24, 25, 26, 27** — practice, measurement, platform, capstone.

## Where the ideas come from

- **[roadmap.sh DevOps](https://roadmap.sh/devops)** — the topic spine, diffed
  against the live roadmap in August 2026. Modules 02, 03, 07, 10, 17 and 26
  close gaps that diff exposed.
- **Published postmortems** — Cloudflare 2019, GitLab 2017, GitHub 2018, Knight
  Capital 2012, AWS S3 2017, Facebook BGP 2021, event-stream 2018. Linked and
  summarised in the student's own reading; the sandbox reconstruction is always a
  simplification, never a facsimile.
- **Brendan Gregg** — the 60-second checklist and USE, for modules 01, 03 and 18.
- **Google SRE Workbook** — SLI/SLO/error-budget and multi-burn-rate alerting
  shape module 24's checks.
- **Gil Tene on coordinated omission** — the argument module 20 makes measurable.
- **DORA 2025** — the metric definitions module 25 grades against.
- **SadServers / iximiuz Labs** — a map of which Linux and networking failures are
  worth teaching. Ideas only: every scenario, name, number and check here is
  written from scratch. See the originality rule in `CURRICULUM.md`.
