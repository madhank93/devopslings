#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# df -h showed 0% used and there was no large file to find, because bytes were
# never the resource in short supply. df -i showed 100% of inodes consumed by
# roughly two thousand session files of a few bytes each.
set -euo pipefail

# 1. Reclaim, by age, and only under sessions. The payload directory holds the
#    settlement batch and is not the problem.
find /srv/spool/sessions -type f -mtime +1 -delete

# 2. The recurrence. The reaper was written during a disk-full incident and
#    matches on -size +1M, so it has never once matched a session file and
#    never will. Prune on the axis that actually runs out.
cat > /usr/local/bin/session-reaper <<'SH'
#!/bin/bash
set -euo pipefail
# Sessions are a few bytes each, so size is meaningless here — what exhausts
# this filesystem is the number of entries. Age is the axis that matters.
find /srv/spool/sessions -type f -mtime +1 -delete
echo "session-reaper: done"
SH
chmod 0755 /usr/local/bin/session-reaper
