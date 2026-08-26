#!/bin/bash
set -e

# Restart the two services that loaded the library
systemctl restart widget.service
systemctl restart cache.service

# Write the answer file
cat > /root/answers/patch.md <<'ANS'
stale_library: libwidget.so.1
found_with: (deleted)
ANS
