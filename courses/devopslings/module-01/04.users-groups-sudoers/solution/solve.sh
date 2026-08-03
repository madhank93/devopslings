#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers

# A process's group list is built by the kernel at login and never revisited.
# usermod edited /etc/group; it cannot reach into an already-running process
# and hand it a credential it did not have.
echo session > /root/answers/why

# Nothing to fix about the file: it is already group deploy, mode 0660, and
# dana is already in deploy. The membership takes effect in any NEW session —
# `su -`, a fresh SSH login, or `newgrp deploy` in the existing shell.
#
# The stale session itself is the thing to replace.
systemctl restart dana-session.service >/dev/null 2>&1 || true

# One command as root, and only that one. Absolute path, so a binary earlier in
# PATH cannot be substituted for it.
cat > /etc/sudoers.d/dana <<'SUDO'
dana ALL=(root) NOPASSWD: /usr/local/bin/deploy-status
SUDO
chmod 0440 /etc/sudoers.d/dana
visudo -cf /etc/sudoers.d/dana >/dev/null
