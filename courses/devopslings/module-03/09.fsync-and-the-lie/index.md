---
kind: lesson
title: "the write returned committed and the record is not there"
description: |
  The vault ledger acknowledged eleven payments and the power went out. Ten of
  them are in the file. The service did everything it was written to do,
  including pushing the record out of its own buffer, and the record still did
  not survive the machine.
name: fsync-and-the-lie
slug: fsync-and-the-lie
createdAt: "2026-08-10"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /var/lib/vault /srv/vault /var/lib/devopslings /root/answers

      # Tear down anything left from a previous run before rebuilding, so the
      # lesson can be reset without the loop and mapper names accumulating.
      umount -l /srv/vault 2>/dev/null || true
      dmsetup remove vault 2>/dev/null || true
      for l in $(losetup -j /var/lib/vault/disk.img 2>/dev/null | cut -d: -f1); do
        losetup -d "$l" 2>/dev/null || true
      done

      # A small volume the lesson can honestly cut the power to. It is a linear
      # device-mapper target over a loop file, which means the table underneath
      # it can be swapped for an error target later — every write in flight and
      # everything still sitting in memory goes away, and the disk keeps only
      # what was actually persisted. That is what a power cut is.
      rm -f /var/lib/vault/disk.img
      dd if=/dev/zero of=/var/lib/vault/disk.img bs=1M count=256 status=none
      loop=$(losetup --find --show /var/lib/vault/disk.img)
      sectors=$(blockdev --getsz "$loop")
      dmsetup create vault --table "0 $sectors linear $loop 0"

      # udev is masked in this image, so nothing creates the mapper node for us.
      dmsetup mknodes vault

      mkfs.ext4 -q -F /dev/mapper/vault
      mount /dev/mapper/vault /srv/vault

      cat > /usr/local/bin/ledger-append <<'PY'
      #!/usr/bin/env python3
      # Appends one record to the vault ledger and reports it committed.
      import sys

      record = " ".join(sys.argv[1:])

      with open("/srv/vault/ledger.log", "a") as f:
          f.write(record + "\n")
          # Push it out of Python's buffer so the record is not left sitting
          # inside this process.
          f.flush()

      print("committed")
      PY
      chmod 0755 /usr/local/bin/ledger-append

      # One record that is genuinely on the disk, so the ledger is not empty and
      # the check can tell a lost write from a wiped volume.
      python3 - <<'PY'
      import os
      with open("/srv/vault/ledger.log", "a") as f:
          f.write("opening-balance 0.00\n")
          f.flush()
          os.fsync(f.fileno())
      d = os.open("/srv/vault", os.O_RDONLY)
      os.fsync(d)
      os.close(d)
      PY

      echo page-cache > /var/lib/devopslings/vault.layer

      cat > /root/questions.txt <<'Q'
      The vault ledger acknowledged eleven payments last night. After the power
      event, ten are in /srv/vault/ledger.log. ledger-append printed "committed"
      for all eleven and exited 0 every time.

        /root/answers/layer     which layer said the write was safe when it was
                                not. One of:

                                  application-buffer   the writing process's own
                                                       userspace buffer
                                  page-cache           the kernel's copy, not yet
                                                       written to the device
                                  device-cache         the drive's volatile cache,
                                                       acknowledged before the platter

      Then make ledger-append durable. The check appends its own records through
      your ledger-append, cuts the power to the volume underneath it, brings it
      back, and requires every acknowledged record to still be there.

      It must keep appending to /srv/vault/ledger.log, and it must keep exiting
      0 with the record acknowledged.
      Q

      echo "scenario ready — /srv/vault is $(findmnt -no SOURCE /srv/vault), ledger has $(wc -l < /srv/vault/ledger.log) record"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want=$(cat /var/lib/devopslings/vault.layer)

      if [ ! -s /root/answers/layer ]; then
        echo "not yet: /root/answers/layer is missing or empty"
        echo "         one of: application-buffer, page-cache, device-cache"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/layer | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          application-buffer)
            echo "not yet: ledger-append already calls flush(), which is exactly the call"
            echo "         that empties the process's own buffer into the kernel. That layer"
            echo "         did what it claimed. The record made it out of the program and"
            echo "         still did not survive the machine."
            ;;
          device-cache)
            echo "not yet: a drive's write cache can certainly lie, and this volume does not"
            echo "         have one — it is a device-mapper target over a file. Nothing here"
            echo "         acknowledged a write to a platter. The record stopped somewhere"
            echo "         earlier than the device."
            ;;
          *)
            echo "not yet: '$got' is not one of application-buffer, page-cache, device-cache"
            ;;
        esac
        exit 1
      fi

      if [ ! -x /usr/local/bin/ledger-append ]; then
        echo "not yet: /usr/local/bin/ledger-append is missing or not executable"
        exit 1
      fi
      if ! grep -q '/srv/vault/ledger.log' /usr/local/bin/ledger-append; then
        echo "not yet: ledger-append no longer writes to /srv/vault/ledger.log."
        echo "         Writing the record somewhere else is not making the write durable."
        exit 1
      fi
      if ! mountpoint -q /srv/vault; then
        echo "not yet: /srv/vault is not mounted — reset the lesson"
        exit 1
      fi

      run=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
      before=$(wc -l < /srv/vault/ledger.log)

      for i in 1 2 3 4 5 6; do
        if ! out=$(ledger-append "txn-$run-$i settled 100.00"); then
          echo "not yet: ledger-append exited non-zero on record $i"
          exit 1
        fi
        case "$out" in
          *committed*) ;;
          *)
            echo "not yet: ledger-append no longer acknowledges the record."
            echo "         It has to keep telling its caller the payment is safe — the"
            echo "         question is whether that is true when it says it."
            exit 1
            ;;
        esac
      done

      acked=$(wc -l < /srv/vault/ledger.log)
      if [ "$acked" -ne $(( before + 6 )) ]; then
        echo "not yet: six records were acknowledged and the ledger holds $(( acked - before ))"
        exit 1
      fi

      # Cut the power. Suspending with --noflush discards everything still in
      # flight rather than politely writing it out first, and swapping the table
      # for an error target means anything the kernel tries to write from here on
      # fails the way it would if the disk had gone away. --nolockfs is what
      # makes it a power cut rather than a clean shutdown: no filesystem freeze,
      # no chance to flush.
      loop=$(losetup -j /var/lib/vault/disk.img | cut -d: -f1)
      if [ -z "$loop" ]; then
        echo "not yet: the vault backing file has no loop device — reset the lesson"
        exit 1
      fi
      sectors=$(blockdev --getsz "$loop")

      dmsetup suspend --noflush --nolockfs vault
      dmsetup load vault --table "0 $sectors error"
      dmsetup resume vault
      umount -l /srv/vault 2>/dev/null || true

      # Power back on: the disk is exactly as persistent storage left it.
      dmsetup suspend vault
      dmsetup load vault --table "0 $sectors linear $loop 0"
      dmsetup resume vault
      dmsetup mknodes vault
      if ! mount /dev/mapper/vault /srv/vault; then
        echo "not yet: the volume did not come back after the power cut — reset the lesson"
        exit 1
      fi

      if ! grep -q 'opening-balance' /srv/vault/ledger.log 2>/dev/null; then
        echo "not yet: the ledger came back without the opening balance, which was"
        echo "         written durably before you started. The volume was wiped rather"
        echo "         than power-cut — reset the lesson."
        exit 1
      fi

      missing=0
      for i in 1 2 3 4 5 6; do
        grep -q "txn-$run-$i " /srv/vault/ledger.log || missing=$(( missing + 1 ))
      done

      if [ "$missing" -gt 0 ]; then
        survived=$(( 6 - missing ))
        echo "not yet: $missing of 6 acknowledged records did not survive the power cut"
        echo "         ($survived still in the ledger)."
        echo ""
        echo "         Every one of them was acknowledged, and the file is shorter than"
        echo "         the number of times the service said 'committed'. flush() moved"
        echo "         the record from the process into the kernel. Nothing has yet"
        echo "         asked the kernel to put it on the disk."
        exit 1
      fi

      echo "PASS — 6 acknowledged records, power cut with the table swapped for an"
      echo "       error target, and all 6 still in the ledger on the other side."
---
