#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Stop the unit rather than the process: Restart=always means killing the PID
# only frees the space until systemd starts it again two seconds later.
set -euo pipefail

systemctl stop log-exporter.service
systemctl disable log-exporter.service
