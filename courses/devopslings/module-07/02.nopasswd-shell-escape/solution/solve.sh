#!/bin/bash
set -e

# 1. Give deploybot log access without root, by group
usermod -aG logreaders deploybot
chgrp logreaders /var/log/app.log
chmod 0640 /var/log/app.log

# 2. Replace the sudoers drop-in with only the legitimate line
cat > /etc/sudoers.d/deploybot <<'SUDO'
deploybot ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service
SUDO
chmod 0440 /etc/sudoers.d/deploybot
visudo -cf /etc/sudoers.d/deploybot

# 3. Write the answer file
cat > /root/answers/sudo.md <<'ANS'
dangerous_binary: awk
mechanism: arbitrary command execution
ANS
