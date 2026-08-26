#!/bin/bash
set -e

# Install alice's key first, with the ownership and modes sshd requires
install -d -m 700 -o alice -g alice /home/alice/.ssh
install -m 600 -o alice -g alice /root/deploy_key.pub /home/alice/.ssh/authorized_keys

# Harden the two directives in place
sed -i 's/^PermitRootLogin .*/PermitRootLogin no/; s/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Validate, then reload (never restart — reload re-reads config without dropping live sessions)
sshd -t
systemctl reload ssh.service

# Write the answer file
cat > /root/answers/ssh.md <<'ANS'
permit_root_login: no
password_authentication: no
validated_with: sshd -t
ANS
