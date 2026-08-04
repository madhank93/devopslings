---
kind: lesson
title: "the fstab line that stops the box half way through boot"
description: |
  Somebody added the archive volume to /etc/fstab, tested it with `mount
  /srv/archive`, and went home. The entry is wrong in a way that only shows up
  when something reads the whole file — which is every boot from now on.
name: mount-and-fstab
slug: mount-and-fstab
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/archive /var/lib/devopslings /root/answers

      umount /srv/archive 2>/dev/null || true
      for l in $(losetup -a | sed -n 's/^\([^:]*\):.*devopslings-arch.*/\1/p'); do
        losetup -d "$l" 2>/dev/null || true
      done
      rm -f /var/lib/devopslings-arch.img
      # There is no udev in a container, so /dev/loopN nodes past the handful the
      # image ships are never created and `losetup --find` fails on them.
      for i in $(seq 0 15); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
      done
      sed -i '\#/srv/archive#d' /etc/fstab 2>/dev/null || true

      truncate -s 200M /var/lib/devopslings-arch.img
      lo=$(losetup --find --show /var/lib/devopslings-arch.img)
      mkfs.ext4 -q -F -L archive "$lo"
      printf '%s\n' "$lo" > /var/lib/devopslings/fstab.loop

      # Put a marker inside so the check can prove the right filesystem is
      # mounted rather than an empty directory of the same name.
      mkdir -p /mnt/seed && mount "$lo" /mnt/seed
      echo "archive-volume-2026" > /mnt/seed/.volume-id
      umount /mnt/seed && rmdir /mnt/seed

      uuid=$(blkid -s UUID -o value "$lo")
      printf '%s\n' "$uuid" > /var/lib/devopslings/fstab.uuid

      # Three separate mistakes, all of which survive `mount /srv/archive`
      # because that command reads only the fields it needs:
      #   - the filesystem type is wrong
      #   - "defaults" is misspelled, so the options field is invalid
      #   - the fsck pass number is 1, which is reserved for the root filesystem
      cat >> /etc/fstab <<EOF
      $lo  /srv/archive  ext3  defaluts  0  1
      EOF

      cat > /root/questions.txt <<'Q'
      /etc/fstab has an entry for /srv/archive that does not work.

      Fix it so that:

        - `findmnt --verify` reports no errors
        - `mount -a` mounts the archive volume at /srv/archive
        - the entry does not stop the boot if the device is missing

      The volume contains a file called .volume-id — the check reads it to
      confirm the right filesystem is mounted, not just that something is.

      Leave the device identified however you think is right; a later lesson
      deals with what happens when device names move.
      Q

      echo "scenario ready — /etc/fstab has a broken /srv/archive entry"
      findmnt --verify 2>&1 | tail -4 || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! grep -q '/srv/archive' /etc/fstab; then
        echo "not yet: there is no /srv/archive entry in /etc/fstab any more"
        echo "         removing the line makes the error go away and loses the volume."
        exit 1
      fi

      # 1. The file has to be valid.
      set +e
      verify_out=$(findmnt --verify 2>&1); verify_rc=$?
      set -e
      if [ "$verify_rc" -ne 0 ]; then
        echo "not yet: findmnt --verify still reports problems:"
        printf '%s\n' "$verify_out" | grep -iE 'error|warning' | head -5 | sed 's/^/         /'
        exit 1
      fi

      # 2. nofail, so a missing device does not hold up the boot.
      line=$(grep '[[:space:]]/srv/archive[[:space:]]' /etc/fstab | grep -v '^[[:space:]]*#' | head -1)
      if ! printf '%s' "$line" | awk '{print $4}' | grep -q 'nofail'; then
        echo "not yet: the entry has no 'nofail' option."
        echo "         its options are: $(printf '%s' "$line" | awk '{print $4}')"
        echo "         without it, a device that is absent at boot stops the machine in"
        echo "         emergency mode waiting for a root password nobody has."
        exit 1
      fi

      # 3. The fsck pass number.
      passno=$(printf '%s' "$line" | awk '{print $6}')
      if [ "${passno:-0}" = "1" ]; then
        echo "not yet: the last field is 1, which is reserved for the root filesystem."
        echo "         Use 2 for other filesystems that should be checked, or 0 to skip."
        exit 1
      fi

      # 4. It must actually mount, from a cold start, via fstab alone.
      umount /srv/archive 2>/dev/null || true
      if mountpoint -q /srv/archive; then
        echo "not yet: /srv/archive could not be unmounted for the test"
        exit 1
      fi

      set +e
      mount_out=$(mount -a 2>&1); mount_rc=$?
      set -e
      if [ "$mount_rc" -ne 0 ]; then
        echo "not yet: 'mount -a' failed:"
        printf '%s\n' "$mount_out" | head -4 | sed 's/^/         /'
        exit 1
      fi

      if ! mountpoint -q /srv/archive; then
        echo "not yet: 'mount -a' succeeded and /srv/archive is not mounted"
        exit 1
      fi

      id=$(cat /srv/archive/.volume-id 2>/dev/null || echo "")
      if [ "$id" != "archive-volume-2026" ]; then
        echo "not yet: /srv/archive is mounted but does not contain the archive volume"
        echo "         .volume-id says '${id:-nothing}', expected 'archive-volume-2026'"
        exit 1
      fi

      echo "PASS — fstab verifies clean, mount -a brings up the archive volume at"
      echo "       /srv/archive, and a missing device will no longer stop the boot."
---
