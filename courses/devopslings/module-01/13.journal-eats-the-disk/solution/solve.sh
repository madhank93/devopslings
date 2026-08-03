#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two halves that people routinely conflate: the setting bounds what journald
# writes from now on, and the vacuum removes what is already on disk. Doing
# only the first leaves the disk exactly as full as it was.
set -euo pipefail

# 1. The cap, as a drop-in rather than an edit to the shipped journald.conf —
#    the package can replace that file on upgrade and take your change with it.
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<'CONF'
[Journal]
SystemMaxUse=32M
# Keep the cap from being spent entirely on one enormous file, so a vacuum has
# something smaller than "everything" to rotate away.
SystemMaxFileSize=8M
CONF

systemctl restart systemd-journald

# 2. The journal already on disk. Vacuum to a size under the cap, not to zero:
#    the point of retention is to retain something.
journalctl --vacuum-size=24M >/dev/null 2>&1

# order-events keeps running throughout; nothing here stops the writer.
