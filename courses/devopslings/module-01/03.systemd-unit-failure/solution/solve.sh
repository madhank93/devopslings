#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The config has to land on disk: the check restarts the service to reject
# fixes that only live in the current process environment.
set -euo pipefail

install -d /etc/checkout-api
echo 'DATABASE_URL=postgres://checkout@db:5432/checkout' > /etc/checkout-api/env
chmod 0640 /etc/checkout-api/env

# StartLimitBurst has already been exhausted by the init, so systemd will
# refuse to start the unit until the rate-limit state is cleared.
systemctl reset-failed checkout-api.service
systemctl start checkout-api.service
systemctl enable checkout-api.service
