#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers
echo throttled > /root/answers/cause

# CPUQuota=20% with the default 100ms period gives the cgroup 20ms of CPU per
# 100ms window. A request needs ~15ms, so any request that starts more than 5ms
# into a period is suspended when the budget runs out and does not run again
# until the next period begins — up to 80ms of wall clock spent runnable and
# not scheduled, on a machine with idle cores.
#
# That is why utilisation looks fine: averaged over a second the cgroup really
# is using ~20% of a core. The stall lives inside the period, and only
# nr_throttled and throttled_usec in cpu.stat show it.
#
# Two levers:
#   * raise the quota, so the budget covers the work
#   * shorten the period, so the same share is handed out in smaller pieces and
#     the worst-case wait shrinks
#
# Both are applied here. The limit stays — it is what stops this service taking
# the whole box during a spike, and it was never the bug.
install -d /etc/systemd/system/pricing-api.service.d
cat > /etc/systemd/system/pricing-api.service.d/cpu.conf <<'CONF'
[Service]
CPUQuota=180%
CPUQuotaPeriodSec=20ms
CONF

systemctl daemon-reload
systemctl restart pricing-api.service
sleep 5
