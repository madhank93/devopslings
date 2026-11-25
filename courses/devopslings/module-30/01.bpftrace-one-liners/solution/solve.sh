#!/bin/sh
set -e
# raw_syscalls rather than syscalls:sys_enter_*: some kernels (Ubuntu's 7.0)
# hand the per-syscall tracepoints to BPF only for syscalls made on CPU 0.
case $(uname -m) in
  x86_64)  read=0  openat=257 ;;
  aarch64) read=63 openat=56 ;;
  *) echo "no syscall numbers for $(uname -m)" >&2; exit 1 ;;
esac
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
d=/root/oneliners
mkdir -p "$d" /root/answers

echo 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' > $d/q1.bt
echo "tracepoint:raw_syscalls:sys_enter /args->id == $openat && strncmp(str(uptr(args->args[1])), \"/etc/\", 5) == 0/ { printf(\"%s %s\\n\", comm, str(uptr(args->args[1]))); }" > $d/q2.bt
echo "tracepoint:raw_syscalls:sys_exit /args->id == $read && args->ret > 0/ { @[comm] = sum(args->ret); }" > $d/q3.bt
cat > $d/q4.bt <<BT
tracepoint:raw_syscalls:sys_enter /args->id == $read && comm == "tailer"/ { @start[curtask->pid] = nsecs; }
tracepoint:raw_syscalls:sys_exit /args->id == $read && @start[curtask->pid]/ { @max_ns = max(nsecs - @start[curtask->pid]); delete(@start[curtask->pid]); }
END { clear(@start); }
BT

run() { timeout -s INT "$2" bpftrace "$d/$1.bt" > "/tmp/$1.out" 2>&1 || true; }
run q1 5; run q2 3; run q3 10; run q4 5

# Only busy's workers count: bpftrace sees every process on the kernel.
top() { grep -E '^@\[(ledger|indexer|mailer|tailer)\]:' "/tmp/$1.out" | awk '{print $NF, $0}' | sort -n | tail -n 1 | sed 's/^[0-9]* @\[\(.*\)\]:.*/\1/'; }
chatty=$(top q1)
reader=$(top q3)
bytes=$(grep -E "^@\[$reader\]:" /tmp/q3.out | awk '{printf "%d", $2 / 10}')
opener=$(grep -E '/etc/busy/' /tmp/q2.out | awk '{print $1}' | sort | uniq -c | sort -n | tail -n 1 | awk '{print $2}')
files=$(grep -E "^$opener /etc/busy/" /tmp/q2.out | awk '{print $2}' | sort -u | xargs -n1 basename | paste -sd, -)
slow=$(awk '/^@max_ns:/ {printf "%d", $2 / 1000000}' /tmp/q4.out)

cat > /root/answers/oneliners.md <<ANS
most-syscalls: $chatty
etc-opener: $opener
etc-files: $files
most-bytes: $reader
bytes-per-second: $bytes
slowest-read-ms: $slow
ANS
cat /root/answers/oneliners.md
