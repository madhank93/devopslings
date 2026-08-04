#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The PKI is entirely correct. The client rejects the certificate as "not yet
# valid" because the client is two years behind the box that issued it — so
# notBefore is, from its point of view, in the future.
set -euo pipefail

install -d /root/answers
echo clockskew > /root/answers/cause

# The skew is scoped to this one unit by a drop-in that was left behind after a
# date-handling test. Removing it puts the service back on the box's clock,
# which was never wrong.
rm -f /etc/systemd/system/ledger-sync.service.d/10-testing.conf
rmdir /etc/systemd/system/ledger-sync.service.d 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed ledger-sync.service >/dev/null 2>&1 || true
