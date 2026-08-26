#!/bin/bash
set -e

# Bind the metrics API to loopback only, and restart it
echo '127.0.0.1:9000' > /etc/metrics/bind.conf
systemctl restart metrics-api.service

# Write the answer file
cat > /root/answers/surface.md <<'ANS'
port_80: public
port_9000: internal
overexposed_port: 9000
restricted_to: 127.0.0.1
ANS
