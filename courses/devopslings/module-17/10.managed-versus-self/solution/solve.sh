#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cat > /root/verdicts/verdicts.txt <<'ANS'
service-1: choice=managed removes=failover adds=cost
service-2: choice=self removes=patching adds=cost
service-3: choice=managed removes=capacity adds=lock-in
service-4: choice=self removes=backups adds=limits
ANS
