#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

dev=$(cat /var/lib/devopslings/fstab.loop)
uuid=$(cat /var/lib/devopslings/fstab.uuid)

# Drop the broken line and write a correct one.
sed -i '\#/srv/archive#d' /etc/fstab

# Four corrections:
#   ext4      the filesystem that is actually there. `mount` guesses the type
#             when you give it a path, which is why testing by hand hid this.
#   defaults  spelled correctly. An unparsable options field is what stops the
#             boot, not a wrong mount point.
#   nofail    a device that is absent at boot is skipped instead of dropping the
#             machine into emergency mode. On anything that is not the root
#             filesystem this is almost always what you want.
#   passno 2  1 is reserved for root. Two filesystems claiming pass 1 is a
#             genuine fsck ordering bug.
#
# UUID rather than the device path, so the entry survives the device being
# renumbered — which is the next lesson.
printf 'UUID=%s  /srv/archive  ext4  defaults,nofail  0  2\n' "$uuid" >> /etc/fstab

systemctl daemon-reload >/dev/null 2>&1 || true
mount -a
