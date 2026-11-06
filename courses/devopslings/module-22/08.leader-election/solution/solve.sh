#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Leadership is a key held under a lease. A node takes the key only when
# nobody holds it (a transaction on its create revision), and runs the job
# only after renewing its lease and reading the key back with a quorum read in
# the same tick. Any error means "not leader", so a node cut off from etcd
# stops within a tick, well before its lease can expire and pass to the other.
set -euo pipefail
cat > /ha/app/scheduler.sh <<'SH'
#!/bin/bash
E="timeout 2 etcdctl --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 --dial-timeout=1s --command-timeout=1s"
me=$(hostname)
lease=""
while :; do
  if [ -z "$lease" ]; then
    lease=$($E lease grant 5 2>/dev/null | awk '{ print $2 }')
  fi
  if [ -n "$lease" ] && $E lease keep-alive --once "$lease" >/dev/null 2>&1; then
    printf 'create("scheduler/leader") = "0"\n\nput scheduler/leader %s --lease=%s\n\n\n' "$me" "$lease" \
      | $E txn >/dev/null 2>&1 || true
    if [ "$($E get scheduler/leader --print-value-only 2>/dev/null)" = "$me" ]; then
      /ha/scheduler/job
    fi
  else
    lease=""
  fi
  sleep 1
done
SH
sleep 8
