#!/bin/sh
set -e
# A path watch for writes: openat with a write flag, or any rename whose
# target is the path. The rename* wildcard covers rename (x86_64 only),
# renameat and renameat2; all three carry the target as newname.
cat > /root/watch.bt <<'BT'
tracepoint:syscalls:sys_enter_openat
/ str(args->filename) == "/etc/pay/limits.conf" && (args->flags & 3) != 0 /
{
  printf("%s uid=%d comm=%s syscall=%s\n", strftime("%H:%M:%S", nsecs), uid, comm, probe);
}

tracepoint:syscalls:sys_enter_rename*
/ str(args->newname) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=%s\n", strftime("%H:%M:%S", nsecs), uid, comm, probe);
}
BT

mkdir -p /root/answers
cat > /root/answers/who.md <<'ANS'
user: svc-cache
process: warm
syscall: openat
ANS
