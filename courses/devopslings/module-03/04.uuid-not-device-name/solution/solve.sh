#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

uuid_b=$(cat /var/lib/devopslings/uuid.backups)
uuid_s=$(cat /var/lib/devopslings/uuid.scratch)

# Drop the device-path entries and key on the filesystem itself.
sed -i '\#/srv/backups#d;\#/srv/scratch2#d' /etc/fstab

# A UUID is written into the filesystem's superblock by mkfs and travels with
# the data. A device path is a name the kernel assigns at attach time and
# belongs to the slot, not to the contents — so it is the one thing in this
# line guaranteed not to be stable.
#
# LABEL= works the same way and is more readable; it is also easier to
# duplicate by accident when a volume is cloned, which is why UUID is the safer
# default for anything that matters.
{
  printf 'UUID=%s  /srv/backups   ext4  defaults,nofail  0  2\n' "$uuid_b"
  printf 'UUID=%s  /srv/scratch2  ext4  defaults,nofail  0  2\n' "$uuid_s"
} >> /etc/fstab

systemctl daemon-reload >/dev/null 2>&1 || true
mount -a
