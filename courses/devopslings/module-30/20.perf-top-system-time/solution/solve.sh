#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# perf record -g -e cpu-clock -p <pid> puts ~70% of samples under
# write -> el0_svc -> __arm64_sys_write -> ksys_write -> vfs_write, called from
# put(); /proc/<pid>/io shows wchar == syscw, one byte per call. put() hands
# the kernel the whole record in one call instead.
set -euo pipefail
install -d /root/answers
printf 'syscall=write\nbytes_per_call=1\n' > /root/answers/systime.txt
python3 - <<'PY'
p = "/usr/local/src/spooler/spooler.c"
s = open(p).read()
old = "    for (size_t i = 0; i < n; i++)\n        write(fd, s + i, 1);\n"
assert old in s
open(p, "w").write(s.replace(old, "    write(fd, s, n);\n"))
PY
make -s -C /usr/local/src/spooler install
systemctl restart spooler.service
sleep 1
