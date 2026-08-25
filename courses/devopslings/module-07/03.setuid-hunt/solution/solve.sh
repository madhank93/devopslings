#!/bin/bash
set -e

# Remove both planted binaries
rm -f /usr/local/bin/maint /opt/tools/backup
rmdir /opt/tools 2>/dev/null || true

# Write the answer file
cat > /root/answers/setuid.md <<'ANS'
unpackaged_setuid: 2
found_with: dpkg -S
ANS
