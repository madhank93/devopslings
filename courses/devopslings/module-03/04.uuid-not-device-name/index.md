---
kind: lesson
title: "after the reboot, the backups were written to the scratch disk"
description: |
  Two volumes, two fstab lines, both correct on the day they were written.
  A reboot enumerated the devices in the other order, every mount point kept
  its name, and the contents behind them swapped.
name: uuid-not-device-name
slug: uuid-not-device-name
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/backups /srv/scratch2 /var/lib/devopslings /root/answers

      umount /srv/backups /srv/scratch2 2>/dev/null || true
      for l in $(losetup -a | sed -n 's/^\([^:]*\):.*devopslings-vol.*/\1/p'); do
        losetup -d "$l" 2>/dev/null || true
      done
      rm -f /var/lib/devopslings-vol*.img
      # There is no udev in a container, so /dev/loopN nodes past the handful the
      # image ships are never created and `losetup --find` fails on them.
      for i in $(seq 0 15); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
      done
      sed -i '\#/srv/backups#d;\#/srv/scratch2#d' /etc/fstab 2>/dev/null || true

      truncate -s 128M /var/lib/devopslings-vol-backups.img
      truncate -s 128M /var/lib/devopslings-vol-scratch.img

      # Attached in this order today, so backups lands on the lower number.
      lo_b=$(losetup --find --show /var/lib/devopslings-vol-backups.img)
      lo_s=$(losetup --find --show /var/lib/devopslings-vol-scratch.img)

      mkfs.ext4 -q -F -L backups "$lo_b"
      mkfs.ext4 -q -F -L scratch "$lo_s"

      mkdir -p /mnt/seed
      mount "$lo_b" /mnt/seed && echo "backups" > /mnt/seed/.volume-id && umount /mnt/seed
      mount "$lo_s" /mnt/seed && echo "scratch" > /mnt/seed/.volume-id && umount /mnt/seed
      rmdir /mnt/seed

      blkid -s UUID -o value "$lo_b" > /var/lib/devopslings/uuid.backups
      blkid -s UUID -o value "$lo_s" > /var/lib/devopslings/uuid.scratch

      # Correct today. Keyed on a name the kernel hands out in attach order.
      cat >> /etc/fstab <<EOF
      $lo_b  /srv/backups   ext4  defaults,nofail  0  2
      $lo_s  /srv/scratch2  ext4  defaults,nofail  0  2
      EOF

      mount -a >/dev/null 2>&1 || true

      cat > /root/questions.txt <<'Q'
      /etc/fstab mounts two volumes by device path:

        /srv/backups    the nightly backup target
        /srv/scratch2   scratch space, wiped weekly

      Both are correct right now. Make them stay correct when the kernel hands
      out those device names in a different order.

      The check will detach both volumes and re-attach them in the OPPOSITE
      order, then run `mount -a` and read the .volume-id file behind each mount
      point. /srv/backups must contain the backups volume.

      Keep both entries, both mount points, and `nofail`.
      Q

      echo "scenario ready — fstab keys /srv/backups and /srv/scratch2 on device paths"
      grep -E '/srv/(backups|scratch2)' /etc/fstab | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      for mp in /srv/backups /srv/scratch2; do
        if ! grep -q "[[:space:]]$mp[[:space:]]" /etc/fstab; then
          echo "not yet: there is no $mp entry in /etc/fstab any more"
          exit 1
        fi
      done

      # Detach both, then re-attach in the opposite order. The kernel reuses the
      # lowest free loop number, so the two volumes swap device names — exactly
      # what a reboot, a new disk or a slower controller does on real hardware.
      umount /srv/backups /srv/scratch2 2>/dev/null || true
      for l in $(losetup -a | sed -n 's/^\([^:]*\):.*devopslings-vol.*/\1/p'); do
        losetup -d "$l" 2>/dev/null || true
      done
      sleep 1
      new_s=$(losetup --find --show /var/lib/devopslings-vol-scratch.img)
      new_b=$(losetup --find --show /var/lib/devopslings-vol-backups.img)

      set +e
      mount_out=$(mount -a 2>&1); mount_rc=$?
      set -e

      report_and_reset() {
        umount /srv/backups /srv/scratch2 2>/dev/null || true
      }

      if [ "$mount_rc" -ne 0 ]; then
        echo "not yet: after the devices were renumbered, 'mount -a' failed:"
        printf '%s\n' "$mount_out" | head -4 | sed 's/^/         /'
        echo "         scratch is now $new_s and backups is now $new_b."
        report_and_reset
        exit 1
      fi

      got_b=$(cat /srv/backups/.volume-id 2>/dev/null || echo "")
      got_s=$(cat /srv/scratch2/.volume-id 2>/dev/null || echo "")

      if [ "$got_b" != "backups" ] || [ "$got_s" != "scratch" ]; then
        echo "not yet: after renumbering, the mount points hold the wrong volumes."
        echo "           /srv/backups   contains: ${got_b:-nothing}"
        echo "           /srv/scratch2  contains: ${got_s:-nothing}"
        echo
        echo "         The kernel assigns loop numbers in attach order, so the volumes"
        echo "         swapped names. fstab named the device rather than the filesystem,"
        echo "         so each mount point faithfully mounted whatever now answers to"
        echo "         that name."
        echo "         Tonight's backups would have been written to scratch, and scratch"
        echo "         is wiped weekly."
        report_and_reset
        exit 1
      fi

      # And the entries must still be safe to boot with.
      for mp in /srv/backups /srv/scratch2; do
        line=$(grep "[[:space:]]$mp[[:space:]]" /etc/fstab | grep -v '^[[:space:]]*#' | head -1)
        if ! printf '%s' "$line" | awk '{print $4}' | grep -q 'nofail'; then
          echo "not yet: the $mp entry lost its 'nofail' option"
          exit 1
        fi
        first=$(printf '%s' "$line" | awk '{print $1}')
        case "$first" in
          /dev/*) echo "not yet: $mp is still keyed on a device path ($first), which is the"
                  echo "         thing that moved. It happens to work right now only because"
                  echo "         the check left the devices in a particular order."
                  exit 1 ;;
        esac
      done

      echo "PASS — devices renumbered (backups is now $new_b, scratch $new_s) and both"
      echo "       mount points still hold the volume they are named after."
---
