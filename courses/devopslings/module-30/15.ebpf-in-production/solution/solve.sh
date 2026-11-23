#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# CO-RE follows BTF, not the version; capabilities follow 5.8. The overhead is
# measured here with the stand-in agent attached.
set -euo pipefail
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

rate() { syscall-bench 3 | awk '{print $1}'; }
off=$(rate)
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' >/tmp/agent.out 2>&1 &
agent=$!
for _ in $(seq 50); do grep -q Attaching /tmp/agent.out && break; sleep 0.2; done
sleep 1
on=$(rate)
kill -INT "$agent"; wait "$agent" || true
pct=$(awk -v a="$off" -v b="$on" 'BEGIN { printf "%.1f", (a - b) / a * 100 }')

cat > /root/answers/ebpf-policy.md <<TXT
web: core=yes privilege=caps
edge: core=yes privilege=caps
batch: core=no privilege=privileged
ci: core=no privilege=caps
box-kernel: $(uname -r)
box-btf: yes — /sys/kernel/btf/vmlinux exists
netmon: reject — bcc compiles on every host with clang against kernel headers, and fails to compile against this box's; ship CO-RE binaries instead
beyla: x86_64-only — its programs fail the verifier on arm64, so the edge group cannot load it
verifier: it rejects programs over the instruction complexity limit or with unbounded loops, and the verdict differs per kernel; each agent is tested on a canary per kernel group, and a load failure disables the agent on that host and alerts rather than retrying
overhead: off=$off on=$on percent=$pct
rollback: if the agent's measured overhead exceeds 2% CPU or p99 latency regresses, the daemonset is scaled to zero per group behind a flag, which detaches the programs
TXT
