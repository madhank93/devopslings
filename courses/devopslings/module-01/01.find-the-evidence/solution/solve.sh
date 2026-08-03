#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The service wrote its last words to stderr. systemd gives every unit's stdout
# and stderr to journald, so the message is in the journal whether or not the
# application ever opened a log file of its own.
set -euo pipefail

install -d /root/answers

echo journal > /root/answers/where

# -u selects the unit, --no-pager stops it trying to be interactive, and -o cat
# strips the timestamp and hostname so what is left is the line the process
# actually printed.
journalctl -u invoice-sync.service --no-pager -o cat \
  | grep -m1 'FATAL' > /root/answers/line
