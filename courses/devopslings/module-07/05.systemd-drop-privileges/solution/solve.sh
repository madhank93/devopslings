#!/bin/bash
set -e

# Overwrite the unit with the hardened version
cat > /etc/systemd/system/webportal.service <<'UNIT'
[Unit]
Description=the customer portal
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/webportal.py
Restart=on-failure

# Drop to an unprivileged user and forbid regaining privilege.
User=www-data
Group=www-data
NoNewPrivileges=yes

# The one capability a non-root process needs to bind a port below 1024, and
# nothing else: AmbientCapabilities grants it to the process, and the bounding
# set caps the maximum so even a compromise cannot acquire more.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

# Reload and restart
systemctl daemon-reload
systemctl restart webportal.service

# Write the answer file
cat > /root/answers/hardening.md <<'ANS'
run_as: www-data
no_new_privileges: yes
bind_capability: CAP_NET_BIND_SERVICE
ANS
