#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Evidence first: State D, wchan submit_bio_wait (stack: blkdev_direct_IO),
# read before resuming, because resuming lets the task finish. A signal is
# only acted on when the task leaves the kernel; an uninterruptible sleep does
# not wake for one, so SIGKILL stays pending until the I/O completes.
set -euo pipefail
install -d /root/answers
pid=$(cat /var/lib/devopslings/dstate.pid)
st=$(awk '/^State:/ {print $2}' "/proc/$pid/status")
w=$(cat "/proc/$pid/wchan")
cat > /root/answers/dstate.txt <<A
state=$st
wchan=$w
why=TASK_UNINTERRUPTIBLE sleep waiting for block I/O on the suspended volume; signals are only delivered on return to user space, so SIGKILL stays pending until the I/O completes
A
dmsetup resume --noudevsync devopslings-vault
