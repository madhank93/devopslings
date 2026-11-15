#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Only us-2 and global resources; the database from the cross-region base
# backup plus WAL (at most ~7 minutes behind), and the call made by the
# incident commander. 5 + 20 + 15 + 10 + 5 + 5 = 60 minutes.
set -euo pipefail
cat > /ha/answers/region-loss.txt <<'TXT'
rpo_minutes: 15
rto_minutes: 60
decision_owner: priya

step: 5  | vm-pool-us2, runbooks-git            | boot the spare app servers in us-2, following the git copy of the runbook
step: 20 | basebackup-us2                       | restore the newest base backup onto a us-2 database server
step: 15 | wal-archive-us2                      | replay the cross-region WAL archive to its end, then promote
step: 10 | bao-escrow-us2                       | two officers open the escrow; import the secrets into a new OpenBao in us-2
step: 5  | registry-mirror-us2                  | deploy the app from the us-2 mirror, pointed at the restored database
step: 5  | dns-provider, pager                  | promote the managed DNS to primary and point www at us-2; tell support
TXT
