#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# strace -f -u ledger shows the last refused call before exit_group(1):
#   openat(AT_FDCWD, "/var/spool/ledger-export/out/.ledger-<day>.<pid>.tmp", O_WRONLY|O_CREAT|...) = -1 EACCES
# The spool directory is root's; the tool creates and renames files in it, so
# the ledger user needs write on the directory, and nobody else does.
set -euo pipefail
install -d /root/answers
cat > /root/answers/silent-exit.txt <<'A'
syscall=openat
errno=EACCES
path=/var/spool/ledger-export/out
A
chown ledger:ledger /var/spool/ledger-export/out
chmod 0750 /var/spool/ledger-export/out
