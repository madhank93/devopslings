#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two separate mechanisms, and both have to be right. The directory decides
# what group a new file gets; the process's umask decides what mode it gets.
# Fixing either one alone leaves the other broken, which is why "chmod 777"
# appears to work — it papers over both by removing the question.
set -euo pipefail

# 1. The directory.
#
#    g+w   so a member of `reports` can create files at all. This is the part
#          that makes the unit stop failing.
#    g+s   the setgid bit: new entries inherit the directory's group instead of
#          the creating process's primary group. Without it, svc-report's files
#          land as group svc-report and publisher — who is in `reports`, not in
#          svc-report — cannot read them no matter what the mode says.
#
#    2775, not 777. World gets r-x, which is enough to traverse and nothing
#    more.
chgrp reports /srv/reports
chmod 2775 /srv/reports

# 2. The process's umask.
#
#    The unit ships UMask=0077, which clears every group and other bit at
#    creation time. The directory's setgid bit cannot undo that: the group is
#    correct and the group permission bits are already gone.
#
#    0027 leaves 0640 on a file — owner rw, group r, other nothing.
mkdir -p /etc/systemd/system/report-writer.service.d
cat > /etc/systemd/system/report-writer.service.d/umask.conf <<'CONF'
[Service]
UMask=0027
CONF

systemctl daemon-reload

# 3. The files that already existed were created under the old rules. They are
#    not what the check looks at, but leaving them wrong is the kind of thing
#    that produces a confusing incident three weeks later.
chgrp reports /srv/reports/report-*.csv 2>/dev/null || true
chmod 0640 /srv/reports/report-*.csv 2>/dev/null || true

systemctl start report-writer.service
