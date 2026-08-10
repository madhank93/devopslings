#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# pswpin is the counter that only moves when a page has to be fetched back from
# swap. anon and file describe how much memory is held; pgfault is in the
# millions on a healthy box. Only pswpin distinguishes a job that is large from
# a job that is paging.
echo pswpin > /root/answers/evidence

# The job touches 300 MB on every pass and was given 200 MB, so a third of its
# working set is evicted and fetched back continuously. The fix is to size the
# limit to what the job touches rather than to what it used to report, which is
# where the original 200 MB came from.
#
# A drop-in rather than an edit of the unit file: the unit is shipped by the
# package and an edit would be lost on the next upgrade, which is the same
# precedence rule the sysctl lesson turned on.
#
# vm.swappiness is deliberately untouched. It would change the ratio of file to
# anonymous reclaim for every process on the machine — this box shares it with
# its host — and the job would still be 100 MB short of what it touches.
install -d /etc/systemd/system/ledger-rollup.service.d
cat > /etc/systemd/system/ledger-rollup.service.d/10-memory.conf <<'CONF'
[Service]
MemoryMax=512M
CONF

systemctl daemon-reload
systemctl restart ledger-rollup.service

# The first pass after a restart faults the whole ledger in for the first time.
# Wait for the job to reach a steady state before anything measures it.
sleep 5
