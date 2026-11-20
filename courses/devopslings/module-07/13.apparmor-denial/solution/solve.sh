#!/bin/sh
set -e
# Allow writes to the one directory the denial names, and quote that denial.
mountpoint -q /sys/kernel/security || mount -t securityfs securityfs /sys/kernel/security
prof=/etc/apparmor.d/receipt-render
grep -q '/var/lib/receipt-render/cache/' "$prof" ||
  sed -i 's|^\(  /var/cache/receipt-render/\*\* rw,\)$|\1\n  /var/lib/receipt-render/cache/** rw,|' "$prof"
apparmor_parser -r "$prof"
systemctl restart receipt-render.service

mkdir -p /root/answers
dmesg | grep 'apparmor="DENIED"' | grep 'profile="receipt-render"' \
  | grep 'name="/var/lib/receipt-render/cache/' | tail -n 1 > /root/answers/denial.md
test -s /root/answers/denial.md
