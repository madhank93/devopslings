#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The compactor dirties 128 MB and fsyncs once: the whole snapshot is queued
# at the device at the same moment, and the ledger's 4 KiB writes wait behind
# it. Flushing every megabyte bounds that queue to one megabyte.
set -euo pipefail

# The range is the one init measured; a student reads it off their own biolatency run.
read -r peak_lo peak_hi _ _ < /var/lib/devopslings/bio.truth
cat > /root/answers/biolatency.md <<TXT
second-mode: ${peak_lo}-${peak_hi} us
cause: metrics-compactor writes a 128 MB snapshot and fsyncs it in one burst every 15 s
TXT
sed -i 's/^flush_every_mb = .*/flush_every_mb = 1/' /etc/metrics-compactor.conf
systemctl restart metrics-compactor.service
