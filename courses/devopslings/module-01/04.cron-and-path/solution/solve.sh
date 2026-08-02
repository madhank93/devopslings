#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two independent bugs, both invisible from an interactive shell:
#
#   1. cron reads `%` in a crontab command as a newline, so the command was
#      truncated at `+%Y` and the rest was fed to it on stdin. The job died on
#      an unterminated `$(` before it ran anything.
#   2. cron's PATH is /usr/bin:/bin. `snapshot` lives in /opt/backup/bin, which
#      only reaches PATH through /etc/profile.d — i.e. only for a human.
set -euo pipefail

# Fix 2 in the script rather than the crontab: the script then works the same
# whether cron, systemd, a CI runner or a person starts it.
cat > /usr/local/bin/nightly-backup.sh <<'SH'
#!/bin/bash
set -euo pipefail

# Do not inherit a PATH from whoever started us. cron's is /usr/bin:/bin.
export PATH=/opt/backup/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[$(date -Is)] nightly-backup starting"
snapshot /srv/checkout /var/backups/checkout
echo "[$(date -Is)] nightly-backup finished"
SH
chmod +x /usr/local/bin/nightly-backup.sh

# Fix 1: escape the percent signs so cron passes them to the shell.
crontab - <<'CRON'
17 3 * * * /usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +\%Y-\%m-\%d).log 2>&1
CRON
