---
title: "eBPF on every host, and the policy that lets it"
---

## The situation

The platform team has been using the eBPF tools on this box all module, and now
wants them everywhere: a CO-RE profiler, a bcc network monitor and Beyla, on all
320 hosts. Security will sign off on a written policy and nothing less.
`/root/fleet/FLEET.md` has the fleet's kernels and the three agents.

The first guess is "the box runs it, so the fleet will". This box is one kernel
on one architecture. The fleet is four kernels on two, and every question an
eBPF agent raises — will it load, what does it need to load, what does it cost —
has a per-kernel answer.

## What decides each answer

**Will it load: CO-RE and BTF.** A libbpf CO-RE binary is compiled once. When it
starts, libbpf reads the running kernel's type information — BTF — and rewrites
each field access to that kernel's struct layout. A kernel built with
`CONFIG_DEBUG_INFO_BTF=y` exposes it at `/sys/kernel/btf/vmlinux`. Without it, a
CO-RE binary has nothing to relocate against; the option there is shipping a BTF
file for that exact kernel (BTFHub), or leaving the group out. BTF is a build
option, not a version: a new kernel built without it has none.

bcc works the other way: it compiles each program with clang on the host, at
start-up, against that host's kernel headers. Every host needs clang, LLVM and
headers that match its kernel. On this box it fails outright — bcc's tools do
not compile against its headers, which is why the module uses libbpf-tools and
bpftrace instead.

**Will the verifier accept it.** Every program is checked before it loads: it
must terminate (loops bounded), stay within the instruction and complexity
limits, and keep to a 512-byte stack. The verdict depends on the kernel, because
the verifier changes between versions and architectures. Beyla 2.5's uprobe
programs pass it on x86_64 and fail it on arm64.

**What it needs to load: privileges.** Before 5.8, loading a tracing program
needs `CAP_SYS_ADMIN` — in practice, a privileged container. Kernel 5.8 split out
`CAP_BPF` (load programs, create maps) and `CAP_PERFMON` (attach to tracepoints,
kprobes and perf events), so on 5.8 and later an agent can run with those two
capabilities and nothing else.

**What it costs.** An eBPF program runs on every event it is attached to. Its
cost is per event, so the overhead depends on the event rate: a hook on every
syscall is invisible on a host doing a thousand a second and large on one doing
millions. Measure it — on a benchmark that stresses exactly the hooked path:

```
$ syscall-bench 3
$ bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' &
$ syscall-bench 3
```

**How it comes off.** An agent rolled out to 320 hosts needs a stated trigger
for removing it and a mechanism that does so without touching each host by hand.

## Your objectives

Fill in every field of `/root/answers/ebpf-policy.md`.

## What you're being graded on

- for each group, whether a CO-RE agent loads as shipped, and whether its
  container needs `CAP_BPF`+`CAP_PERFMON` or a privileged container
- this box's kernel release, and whether it has BTF, with where you looked
- a verdict on netmon and on Beyla, with the reason
- a limit the verifier enforces, and what the rollout does when it rejects a
  program on some kernel
- the overhead measured on this box: `syscall-bench` without and with the
  stand-in agent, and the slowdown
- what triggers a rollback, and how the agents are removed

<details>
<summary>Hint 1 — two columns, two rules</summary>

`core` depends only on the BTF column. `privilege` depends only on the kernel
version. They disagree for exactly one group: read `ci` twice.

</details>

<details>
<summary>Hint 2 — this box</summary>

```
$ uname -r
$ ls -l /sys/kernel/btf/vmlinux
$ zcat /proc/config.gz | grep DEBUG_INFO_BTF
```

</details>

<details>
<summary>Hint 3 — the overhead is zero</summary>

If bpftrace did not print `Attaching 1 probe...`, nothing was attached while the
benchmark ran. It needs tracefs: `mount -t tracefs tracefs /sys/kernel/tracing`.

</details>

<details>
<summary>Solution</summary>

```
web: core=yes privilege=caps
edge: core=yes privilege=caps
batch: core=no privilege=privileged
ci: core=no privilege=caps
box-kernel: <uname -r>
box-btf: yes — /sys/kernel/btf/vmlinux exists
netmon: reject — bcc compiles on every host with clang against its kernel headers, and fails to compile against this box's; ship CO-RE binaries instead
beyla: x86_64-only — its programs fail the verifier on arm64, so the edge group cannot load it
verifier: it rejects programs over the complexity limit or with unbounded loops, and the verdict differs per kernel; each agent is tested on a canary per kernel group, and a load failure disables the agent on that host and alerts
overhead: off=<rate> on=<rate> percent=<slowdown>
rollback: if measured overhead exceeds 2% CPU or p99 regresses, the daemonset is scaled to zero per group behind a flag, which detaches the programs
```

### The ways this goes wrong

- **Deciding CO-RE by version.** `ci` runs 5.15, newer than anything CO-RE
  needs, and was built without BTF. The agent fails to load there.
- **Privileged everywhere.** It works, and it hands every agent container full
  root on the host where two capabilities would do. Only `batch`, on 5.4, has no
  narrower option.
- **bcc because it already works on someone's laptop.** It compiles against the
  headers of each host it lands on; every kernel update is a new chance to fail.
- **Beyla approved fleet-wide.** The edge group is arm64, where it does not load.
- **Overhead quoted from a vendor page.** The cost is per event, and the event
  rate is yours. A syscall hook costs tens of percent on a syscall-bound
  benchmark; on a typical service it is far less. Measure on the hooked path,
  then on your workload.

</details>
