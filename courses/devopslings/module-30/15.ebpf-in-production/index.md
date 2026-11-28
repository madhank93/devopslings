---
kind: lesson
title: "eBPF on every host, and the policy that lets it"
description: |
  The platform team wants eBPF agents — a profiler, a network monitor and
  Beyla — on all 320 hosts. Four kernel groups, two architectures, and one box
  to measure on. Write the adoption policy: which hosts can load what, with
  which privileges, at what measured cost, and how it all comes off again.
name: ebpf-in-production
slug: ebpf-in-production
createdAt: "2026-11-23"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -e
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
      rm -rf /root/fleet /root/answers/ebpf-policy.md /usr/local/bin/syscall-bench
      install -d /root/fleet /root/answers /usr/local/src

      cat > /usr/local/src/syscall-bench.c <<'C'
      /* Calls getppid(2) in a loop for N seconds and prints the rate. */
      #include <stdio.h>
      #include <stdlib.h>
      #include <time.h>
      #include <unistd.h>
      #include <sys/syscall.h>
      int main(int argc, char **argv) {
        double secs = argc > 1 ? atof(argv[1]) : 3, el;
        struct timespec a, b;
        long n = 0;
        clock_gettime(CLOCK_MONOTONIC, &a);
        do {
          for (int i = 0; i < 10000; i++) syscall(SYS_getppid);
          n += 10000;
          clock_gettime(CLOCK_MONOTONIC, &b);
          el = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
        } while (el < secs);
        printf("%.0f syscalls/s\n", n / el);
        return 0;
      }
      C
      gcc -O2 -o /usr/local/bin/syscall-bench /usr/local/src/syscall-bench.c

      cat > /root/fleet/FLEET.md <<'MD'
      # The fleet

      Kernel inventory, from the CMDB:

      | group | hosts | arch    | kernel                       | CONFIG_DEBUG_INFO_BTF |
      |-------|-------|---------|------------------------------|-----------------------|
      | web   | 140   | x86_64  | 6.1.0-28 (Debian 12)         | y                     |
      | edge  | 60    | aarch64 | 6.8.0-49 (Ubuntu 24.04)      | y                     |
      | batch | 80    | x86_64  | 5.4.0-200 (Ubuntu 20.04)     | n                     |
      | ci    | 40    | x86_64  | 5.15.160 (in-house build)    | n                     |

      Agents the platform team proposes for every host:

      1. **profiler** — a continuous CPU profiler built on libbpf with CO-RE,
         like the libbpf-tools on this box. Ships one compiled binary.
      2. **netmon** — a bcc-based network monitor. It compiles its eBPF programs
         on each host at start-up, with clang, against that host's kernel headers.
      3. **beyla** — Grafana Beyla 2.5, for RED metrics and spans without code
         changes.

      Every agent runs as a container. The security team will not run privileged
      containers unless the policy says why nothing less works.

      Overhead: each agent's cost is measured, on this box, as the slowdown of
      `syscall-bench` with the agent attached. Stand-in for an agent that hooks
      every syscall:

          bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'
      MD

      cat > /root/answers/ebpf-policy.md <<'TXT'
      # eBPF adoption policy. One line per field; replace every ?.

      # Per group: can a CO-RE agent load as shipped (core=yes|no), and the least
      # the agent's container needs to load programs (privilege=caps|sys_admin|privileged):
      # caps = CAP_BPF+CAP_PERFMON, sys_admin = CAP_SYS_ADMIN added, privileged = --privileged.
      web: core=? privilege=?
      edge: core=? privilege=?
      batch: core=? privilege=?
      ci: core=? privilege=?

      # This box, as evidence.
      box-kernel: ?
      box-btf: ?

      # Each proposed agent other than the profiler: approve, reject or x86_64-only — then why.
      netmon: ?
      beyla: ?

      # What the verifier limits, and what the rollout does when it rejects a program.
      verifier: ?

      # syscall-bench on this box, without and with the stand-in agent attached.
      overhead: off=? on=? percent=?

      # What triggers a rollback, and how the agents come off the fleet.
      rollback: ?
      TXT

      echo "scenario ready: the fleet is described in /root/fleet/FLEET.md;"
      echo "the policy template is /root/answers/ebpf-policy.md."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 90
    run: |
      python3 - <<'PY'
      import os, platform, re, subprocess, sys

      ANSWER = "/root/answers/ebpf-policy.md"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      try:
          text = open(ANSWER).read()
      except OSError:
          no(f"{ANSWER} is missing. Reset the lesson to get the template back.")

      def field(k):
          for line in text.splitlines():
              m = re.match(rf"\s*{re.escape(k)}\s*:\s*(.*)", line, re.I)
              if m:
                  return m.group(1).strip()
          return ""

      def filled(k):
          v = field(k)
          if not v or "?" in v:
              no(f"{k} in {ANSWER} is not filled in.")
          return v

      # ---- per group: CO-RE needs BTF; CAP_BPF/CAP_PERFMON exist from 5.8 ----
      truth = {"web": ("yes", {"caps"}), "edge": ("yes", {"caps"}),
               "batch": ("no", {"sys_admin", "privileged"}), "ci": ("no", {"caps"})}
      for g, (core, priv) in truth.items():
          v = filled(g).lower()
          c = re.search(r"\bcore\s*=\s*(\w+)", v)
          p = re.search(r"\bprivilege\s*=\s*([\w-]+)", v)
          if not c or not p:
              no(f"{g} needs core=yes|no and privilege=caps|sys_admin|privileged.")
          if c.group(1) != core:
              if core == "yes":
                  no(f"{g} says core={c.group(1)}. Its kernel was built with BTF, and BTF is",
                     "all a CO-RE binary needs to relocate its programs to that kernel.")
              if g == "ci":
                  no("ci says core=yes. A 5.15 kernel is new enough for every CO-RE feature,",
                     "and this one was built without BTF: no /sys/kernel/btf/vmlinux, nothing",
                     "for libbpf to relocate against. The version does not decide it.")
              no(f"{g} says core=yes. Its kernel was built without BTF, so a CO-RE binary",
                 "has no type information to relocate against there.")
          if p.group(1) not in priv:
              if priv == {"caps"}:
                  no(f"{g} says privilege={p.group(1)}. Its kernel is 5.8 or later, which split",
                     "CAP_BPF and CAP_PERFMON out of CAP_SYS_ADMIN; a tracing agent needs those",
                     "two, not CAP_SYS_ADMIN or a privileged container.")
              no(f"{g} says privilege={p.group(1)}. CAP_BPF and CAP_PERFMON arrived in 5.8; on",
                 f"{g}'s 5.4 kernel loading a program needs CAP_SYS_ADMIN (sys_admin). Say so,",
                 "so the security team can weigh it.")

      # ---- this box ---------------------------------------------------------
      if filled("box-kernel") != platform.release():
          no(f"box-kernel is '{field('box-kernel')}'; this box's kernel is what uname -r prints.")
      btf = os.path.exists("/sys/kernel/btf/vmlinux")
      v = filled("box-btf").lower()
      said = re.match(r"\s*(yes|no)\b", v)
      if not said:
          no("box-btf should start with yes or no.")
      if (said.group(1) == "yes") != btf:
          no(f"box-btf says {said.group(1)}. Look again: /sys/kernel/btf/vmlinux is where a",
             "kernel built with BTF exposes it.")
      if not re.search(r"/sys/kernel/btf/vmlinux|config_debug_info_btf", v):
          no("box-btf does not say where you looked: /sys/kernel/btf/vmlinux, or",
             "CONFIG_DEBUG_INFO_BTF in /proc/config.gz.")

      # ---- the agents -------------------------------------------------------
      def verdict(k, ok, why, what):
          v = filled(k).lower()
          m = re.match(r"\s*(approve|reject|x86_64-only|x86-only)\b", v)
          if not m:
              no(f"{k} should start with approve, reject or x86_64-only.")
          if m.group(1) not in ok:
              return m.group(1)
          rest = v[m.end():]
          if len(rest.split()) < 5 or not re.search(why, rest):
              no(f"{k}'s reason, '{rest.strip(' -—:')}', does not say {what}.")
          return None

      bad = verdict("netmon", {"reject"},
                    r"\b(compil\w*|headers?|clang|llvm|co-?re|btf)\b",
                    "what bcc needs on every host that a CO-RE binary does not")
      if bad:
          no(f"netmon says {bad}. bcc compiles its programs on each host at start-up,",
             "against that host's kernel headers: clang and headers on 320 hosts, and a",
             "failure on any kernel whose headers do not match — bcc already fails to",
             "compile against this box's. The profiler shows the alternative.")
      bad = verdict("beyla", {"reject", "x86_64-only", "x86-only"},
                    r"\b(arm64|aarch64|arm|verifier|edge)\b",
                    "which hosts it cannot load on, and why")
      if bad:
          no("beyla says approve. Beyla 2.5's programs fail the verifier on aarch64,",
             "and the edge group is aarch64: approved fleet-wide, it fails to load on 60",
             "hosts. Reject it, or approve it for x86_64 only.")

      # ---- verifier ---------------------------------------------------------
      v = filled("verifier").lower()
      if not re.search(r"\b(instructions?|complexity|loops?|bounded|stack|512|1m|million|4096|termina\w*|unbounded)\b", v):
          no("verifier does not name a limit it enforces — program size or complexity,",
             "bounded loops, or the 512-byte stack.")
      if not re.search(r"\b(reject\w*|refus\w*|fails?|failed|failure|load\w*)\b", v) or \
         not re.search(r"\b(canary|staged?|per[- ]group|per[- ]kernel|test\w*|skip\w*|fall ?back|fail[- ]open|alert\w*|exclud\w*|disabl\w*|keeps? running|degrad\w*)\b", v):
          no("verifier does not say what the rollout does when a program is rejected on",
             "some kernel — verdicts differ per kernel, as Beyla shows on arm64. Test per",
             "kernel group before rollout, and say what the agent does when a load fails.")

      # ---- overhead ---------------------------------------------------------
      v = filled("overhead").lower().replace(",", "").replace("_", "")
      nums = {}
      for k in ("off", "on", "percent"):
          m = re.search(rf"\b{k}\s*=\s*([0-9]+(?:\.[0-9]+)?)", v)
          if not m:
              no(f"overhead needs {k}= as a number (off/on in syscalls/s from syscall-bench).")
          nums[k] = float(m.group(1))
      off, on, pct = nums["off"], nums["on"], nums["percent"]
      if off <= 0 or on <= 0:
          no("overhead's off and on rates should be syscall-bench's syscalls/s.")
      real = (off - on) / off * 100
      if abs(real - pct) > 2:
          no(f"overhead says percent={pct:g}, and off={off:.0f} on={on:.0f} is a {real:.1f}% slowdown.")
      def bench():
          r = subprocess.run(["syscall-bench", "1"], capture_output=True, text=True)
          m = re.match(r"\s*([0-9]+)", r.stdout)
          return float(m.group(1)) if m else None
      g_off = bench()
      if g_off and not (g_off / 3 <= off <= g_off * 3):
          no(f"overhead's off={off:.0f}, and syscall-bench on this box just ran at",
             f"{g_off:.0f} syscalls/s. Measure here, with syscall-bench.")
      # The grader attaches the stand-in agent itself, so `on` is a measurement.
      agent = subprocess.Popen(
          ["bpftrace", "-e", "tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }"],
          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
      attached, seen = False, []
      for line in agent.stdout:
          seen.append(line.rstrip())
          if "Attaching" in line:
              attached = True
              break
      g_on = bench() if attached else None
      agent.send_signal(2)
      try:
          agent.communicate(timeout=10)
      except subprocess.TimeoutExpired:
          agent.kill()
      if not attached or not g_off or not g_on:
          no("the grader could not measure syscall-bench with and without the stand-in",
             "agent, so overhead cannot be checked. bpftrace said:",
             *(seen[-6:] or ["(nothing)"]))
      if not (g_on / 2 <= on <= g_on * 2):
          no(f"overhead's on={on:.0f}, and syscall-bench with the stand-in agent attached",
             f"just ran at {g_on:.0f} syscalls/s. Measure with the agent attached.")
      g_pct = (g_off - g_on) / g_off * 100
      if abs(g_pct - pct) > 12:
          no(f"overhead says {pct:g}%; the grader just measured {g_pct:.0f}% with the same",
             "benchmark and agent. Measure off and on back to back, on this box.")
      if pct < 5:
          no(f"overhead says {pct:g}%. A program on every syscall costs far more than that",
             "on a syscall-only benchmark — check the agent was attached while the",
             "benchmark ran (bpftrace prints 'Attaching 1 probe...').")

      # ---- rollback ---------------------------------------------------------
      v = filled("rollback").lower()
      if not re.search(r"\b(overhead|cpu|latency|p99|slo|errors?|threshold|budget|regress\w*|percent|crash\w*|panic\w*|%)", v):
          no("rollback does not say what triggers it — a measured threshold, not a feeling.")
      if not re.search(r"\b(uninstall\w*|remov\w*|disabl\w*|stop\w*|flag|daemonset|revert\w*|roll(ed|s)? back|delet\w*|scale\w*|detach\w*|unload\w*)\b", v):
          no("rollback does not say how the agents come off the fleet.")

      print("PASS — CO-RE where there is BTF, capabilities from 5.8, netmon and fleet-wide")
      print("       Beyla rejected, and the overhead measured on this box.")
      PY
