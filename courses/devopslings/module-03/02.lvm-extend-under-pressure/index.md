---
kind: lesson
title: "you added the disk, you grew the volume, and df has not moved"
description: |
  /srv/data is at 96% and there is a spare disk in the box. Adding it to the
  volume group and extending the logical volume are two steps; the filesystem
  is a third, and it is the one that makes df change. The service stays up
  throughout.
name: lvm-extend-under-pressure
slug: lvm-extend-under-pressure
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv /var/lib/devopslings /root/answers

      # Tear down anything left from a previous run.
      systemctl stop ingest.service >/dev/null 2>&1 || true
      umount /srv/data 2>/dev/null || true
      vgremove -f -qq datavg >/dev/null 2>&1 || true
      for l in $(losetup -a | sed -n 's/^\([^:]*\):.*devopslings-pv.*/\1/p'); do
        losetup -d "$l" 2>/dev/null || true
      done
      rm -f /var/lib/devopslings-pv*.img
      # There is no udev in a container, so /dev/loopN nodes past the handful the
      # image ships are never created and `losetup --find` fails on them.
      for i in $(seq 0 15); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
      done
      install -d /srv/data

      # PV 1 becomes the volume group; PV 2 is the "spare disk" the student has
      # been given and has not yet used.
      truncate -s 320M /var/lib/devopslings-pv1.img
      truncate -s 320M /var/lib/devopslings-pv2.img
      lo1=$(losetup --find --show /var/lib/devopslings-pv1.img)
      lo2=$(losetup --find --show /var/lib/devopslings-pv2.img)
      printf '%s\n%s\n' "$lo1" "$lo2" > /var/lib/devopslings/lvm.loops

      pvcreate -qq "$lo1" "$lo2"
      vgcreate -qq datavg "$lo1"
      # -Zn because there is no udev in a container to create the node before
      # lvcreate wants to zero it.
      lvcreate -qq -Zn -L 280M -n datalv datavg >/dev/null 2>&1
      vgmknodes >/dev/null 2>&1 || true
      mkfs.ext4 -q -F /dev/datavg/datalv
      mount /dev/datavg/datalv /srv/data

      # Fill it to ~96% with something that must not be deleted.
      install -d /srv/data/ingest
      dd if=/dev/zero of=/srv/data/ingest/backlog.bin bs=1M count=240 status=none
      sha256sum /srv/data/ingest/backlog.bin | awk '{print $1}' \
        > /var/lib/devopslings/lvm.payload.sha256

      # A writer that keeps running and keeps failing while the disk is full.
      cat > /usr/local/bin/ingest <<'SH'
      #!/bin/bash
      n=0
      while :; do
        n=$((n + 1))
        if printf 'record %d\n' "$n" >> /srv/data/ingest/stream.log 2>/dev/null; then
          echo "$n" > /srv/data/ingest/.count 2>/dev/null || true
        else
          echo "ingest: cannot write — no space" >&2
        fi
        sleep 0.5
      done
      SH
      chmod 0755 /usr/local/bin/ingest

      cat > /etc/systemd/system/ingest.service <<'UNIT'
      [Unit]
      Description=Ingest writer
      [Service]
      ExecStart=/usr/local/bin/ingest
      Restart=always
      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable ingest.service >/dev/null 2>&1 || true
      systemctl restart ingest.service >/dev/null 2>&1 || true
      sleep 2

      # Record the writer's PID. "Did not restart" is a fact about this process,
      # not about elapsed time — the check runs seconds after init, so any
      # age-based test would be meaningless.
      systemctl show -p MainPID --value ingest.service > /var/lib/devopslings/lvm.ingest.pid

      cat > /root/questions.txt <<'Q'
      /srv/data is nearly full and ingest.service cannot write.

      There is a spare physical volume already prepared and not yet in use —
      `pvs` will show you both.

      Grow /srv/data to at least 500M of capacity, using that spare, without:

        - deleting /srv/data/ingest/backlog.bin (the check verifies its checksum)
        - unmounting /srv/data
        - restarting ingest.service

      ingest.service must be writing again when you are done.
      Q

      echo "scenario ready — /srv/data is at $(df -h /srv/data | awk 'NR==2{print $5}') and ingest is failing"
      df -h /srv/data | tail -1

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! mountpoint -q /srv/data; then
        echo "not yet: /srv/data is not mounted — reset the lesson"
        exit 1
      fi

      want_sha=$(cat /var/lib/devopslings/lvm.payload.sha256)
      if [ ! -f /srv/data/ingest/backlog.bin ]; then
        echo "not yet: /srv/data/ingest/backlog.bin is gone"
        echo "         deleting the backlog frees space and loses the data the volume"
        echo "         exists to hold. Grow the volume instead."
        exit 1
      fi
      got_sha=$(sha256sum /srv/data/ingest/backlog.bin | awk '{print $1}')
      if [ "$got_sha" != "$want_sha" ]; then
        echo "not yet: backlog.bin has been modified or truncated"
        exit 1
      fi

      # Capacity as the filesystem reports it — not as the LV reports it.
      size_mb=$(df -BM --output=size /srv/data | tail -1 | tr -dc '0-9')
      if [ "${size_mb:-0}" -lt 500 ]; then
        lv_mb=$(lvs --noheadings --units m -o lv_size datavg/datalv 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)
        echo "not yet: the filesystem on /srv/data is ${size_mb}M, and it needs at least 500M"
        if [ "${lv_mb:-0}" -ge 500 ]; then
          echo "         the logical volume is already ${lv_mb}M — the space is allocated."
          echo "         The filesystem was created at the old size and does not go looking"
          echo "         for more. That is a third step, and it is the one df reflects."
        else
          echo "         the logical volume is ${lv_mb:-?}M. Add the spare PV to the volume"
          echo "         group first, then extend the LV, then the filesystem."
        fi
        df -h /srv/data | sed 's/^/           /'
        exit 1
      fi

      # The service must have kept running throughout.
      if ! systemctl is-active --quiet ingest.service; then
        echo "not yet: ingest.service is not running"
        exit 1
      fi
      want_pid=$(cat /var/lib/devopslings/lvm.ingest.pid 2>/dev/null || echo 0)
      got_pid=$(systemctl show -p MainPID --value ingest.service)
      if [ "${got_pid:-0}" != "${want_pid:-1}" ]; then
        echo "not yet: ingest.service is running as PID $got_pid; it was $want_pid before"
        echo "         it has been restarted. Growing a volume with LVM is an online"
        echo "         operation — the whole reason to use it is that the writer never"
        echo "         stops. Reset the lesson and grow it underneath a running process."
        exit 1
      fi

      # And it must actually be writing again.
      c1=$(cat /srv/data/ingest/.count 2>/dev/null || echo 0)
      sleep 3
      c2=$(cat /srv/data/ingest/.count 2>/dev/null || echo 0)
      if [ "${c2:-0}" -le "${c1:-0}" ]; then
        echo "not yet: there is space now, but ingest is not writing ($c1 -> $c2)"
        journalctl -u ingest.service --no-pager -o cat -n 3 2>&1 | sed 's/^/         /'
        exit 1
      fi

      echo "PASS — /srv/data is now ${size_mb}M, backlog.bin intact, and ingest is still"
      echo "       PID $got_pid — it never stopped."
---
