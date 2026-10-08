#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The cap takes effect when journald restarts, which also vacuums archived files
# down to it; the explicit vacuum trims further while keeping recent history.
set -euo pipefail

# 1. The cap, as a drop-in rather than an edit to the shipped journald.conf —
#    the package can replace that file on upgrade and take your change with it.
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<'CONF'
[Journal]
SystemMaxUse=32M
# Vacuuming removes whole archived files, so this is how much history goes at once.
SystemMaxFileSize=8M
CONF

systemctl restart systemd-journald

# 2. The journal already on disk. Vacuum to a size under the cap, not to zero:
#    the point of retention is to retain something.
journalctl --vacuum-size=24M >/dev/null 2>&1

# order-events keeps running throughout; nothing here stops the writer.
