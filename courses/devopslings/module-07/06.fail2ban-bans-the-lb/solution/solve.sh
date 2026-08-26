#!/bin/bash
set -e

# Add the load balancer (and loopback) to the ignore list
cat > /etc/fail2ban/jail.local <<'CFG'
[DEFAULT]
backend = polling

[sshd]
enabled  = true
logpath  = /var/log/auth.log
maxretry = 5
findtime = 600
bantime  = 3600
ignoreip = 127.0.0.1/8 10.9.0.9
CFG

# Validate the config
fail2ban-client -t

# Write the answer file
cat > /root/answers/fail2ban.md <<'ANS'
wrongly_banned_ip: 10.9.0.9
fixed_with: ignoreip
ANS
