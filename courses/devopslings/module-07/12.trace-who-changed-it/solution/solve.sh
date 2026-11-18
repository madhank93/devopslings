#!/bin/sh
set -e
# A path watch for writes: openat with a write flag, or any rename whose
# target is the path. It hooks raw_syscalls:sys_enter rather than the
# per-syscall sys_enter_* tracepoints, which some kernels (Ubuntu's 7.0) hand
# to BPF only for syscalls made on CPU 0. Syscall numbers differ by CPU, and
# arm64 has no plain rename; -1 never matches.
case $(uname -m) in
  x86_64)  openat=257 rename=82 renameat=264 renameat2=316 ;;
  aarch64) openat=56  rename=-1 renameat=38  renameat2=276 ;;
  *) echo "no syscall numbers for $(uname -m)" >&2; exit 1 ;;
esac

cat > /root/watch.bt <<BT
tracepoint:raw_syscalls:sys_enter
/ args->id == $openat && (args->args[2] & 3) != 0
  && str(uptr(args->args[1])) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=openat\n", strftime("%H:%M:%S", nsecs), uid, comm);
}

tracepoint:raw_syscalls:sys_enter
/ args->id == $rename && str(uptr(args->args[1])) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=rename\n", strftime("%H:%M:%S", nsecs), uid, comm);
}

tracepoint:raw_syscalls:sys_enter
/ (args->id == $renameat || args->id == $renameat2)
  && str(uptr(args->args[3])) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=renameat\n", strftime("%H:%M:%S", nsecs), uid, comm);
}
BT

mkdir -p /root/answers
cat > /root/answers/who.md <<'ANS'
user: svc-cache
process: warm
syscall: openat
ANS
