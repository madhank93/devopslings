#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# key access first, in the order that cannot lock anyone out: the way in has to
# work before the way in that exists today is taken away
install -d -m 700 /home/deploy/.ssh
cat /lab/ops_key.pub >> /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# sshd keeps the first value it reads for a keyword, and sshd_config includes
# the drop-in directory on its first line, so editing the main file alone
# changes nothing
cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<'CONF'
# Written by the image build. Do not edit by hand.
PasswordAuthentication no
CONF

sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

# check before applying, then reload rather than restart so established
# sessions are not taken down with the daemon
sshd -t
systemctl reload ssh.service

install -d /root/answers
cat > /root/answers/ssh.md <<'ANS'
overriding_file: /etc/ssh/sshd_config.d/50-cloud-init.conf
first_or_last_wins: first
ANS
