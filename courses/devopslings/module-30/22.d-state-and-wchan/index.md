---
kind: lesson
title: "kill -9, and it is still there"
description: |
  The vault verifier has been stuck for an hour. kill -9 did nothing, and the
  load average has gone up by one and stayed there. It looks like the blocked
  pipe from module 01, but that one died to a signal. This one is in D: an
  uninterruptible sleep inside the kernel, waiting for a disk that has stopped
  answering. Read what it is waiting on from the live task, explain why the
  signal cannot land, and let it finish.
name: d-state-and-wchan
slug: d-state-and-wchan
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      dev=devopslings-vault
      # The device mapper and loop devices belong to the host kernel, so a
      # previous attempt's device outlives the container: resume it first, or
      # its readers can never exit.
      if dmsetup info "$dev" >/dev/null 2>&1; then
        dmsetup resume --noudevsync "$dev" 2>/dev/null || true
      fi
      systemctl stop vault-verify.service vault-path.service 2>/dev/null || true
      systemctl reset-failed vault-verify.service vault-path.service 2>/dev/null || true
      dmsetup remove --noudevsync "$dev" 2>/dev/null || true
      for l in $(losetup -a | sed -n 's/^\([^:]*\):.*devopslings-vault.*/\1/p'); do
        losetup -d "$l" 2>/dev/null || true
      done
      rm -f /var/lib/devopslings-vault.img /dev/vault /root/answers/dstate.txt
      install -d /root/answers /var/lib/devopslings
      # No udev in a container: loop and device-mapper nodes are made by hand.
      for i in $(seq 0 15); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
      done

      truncate -s 64M /var/lib/devopslings-vault.img
      lo=$(losetup --find --show /var/lib/devopslings-vault.img)
      dmsetup create --noudevsync "$dev" --table "0 131072 linear $lo 0"
      mm=$(dmsetup info -c --noheadings -o major,minor "$dev" | tr -d ' ')
      mknod /dev/vault b "${mm%:*}" "${mm#*:}"
      dmsetup table "$dev" > /var/lib/devopslings/dstate.table

      # The storage path: when the box shuts down, it is resumed, so a reader
      # stuck on it can exit and the container can stop.
      cat > /etc/systemd/system/vault-path.service <<'UNIT'
      [Unit]
      Description=Vault volume path

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/true
      ExecStop=-/usr/sbin/dmsetup resume --noudevsync devopslings-vault
      UNIT
      cat > /etc/systemd/system/vault-verify.service <<'UNIT'
      [Unit]
      Description=Verify the vault volume reads end to end
      After=vault-path.service

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/dd if=/dev/vault of=/dev/null bs=64k iflag=direct
      UNIT
      systemctl daemon-reload
      systemctl start vault-path.service

      # The storage path fails over: I/O to the volume is queued, not failed.
      dmsetup suspend --noudevsync "$dev"
      systemctl start --no-block vault-verify.service

      wchan=""; last=""; same=0
      for _ in $(seq 1 80); do
        pid=$(systemctl show -p MainPID --value vault-verify.service 2>/dev/null || echo 0)
        w=""; st=""
        if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/wchan" ]; then
          w=$(cat "/proc/$pid/wchan" 2>/dev/null || true)
          st=$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
        fi
        if [ "$st" = D ] && [ -n "$w" ] && [ "$pid:$w" = "$last" ]; then same=$((same + 1)); else same=0; fi
        last="$pid:$w"
        if [ "$same" -ge 4 ]; then wchan=$w; break; fi
        sleep 0.25
      done
      if [ -z "$wchan" ]; then
        dmsetup resume --noudevsync "$dev" || true
        echo "scenario setup failed: the verifier did not settle in D state" >&2
        exit 1
      fi
      echo "$pid" > /var/lib/devopslings/dstate.pid
      echo "$wchan" > /var/lib/devopslings/dstate.wchan

      echo "scenario ready — vault-verify.service has been running since $(date +%T) and has read nothing."
      echo "Write your findings to /root/answers/dstate.txt before you change anything."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=/root/answers/dstate.txt
      dev=devopslings-vault
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed 's/^ *//; s/ *$//'; }
      st=$(field state | tr -d ' "'); w=$(field wchan | tr -d ' "'); why=$(field why)
      if [ -z "$st" ] || [ -z "$w" ] || [ -z "$why" ]; then
        echo "not yet: $ans needs state=, wchan= and why=: the verifier's state letter and the kernel"
        echo "         function it sleeps in, read from /proc/<pid> while it is stuck, and why kill -9"
        echo "         did not end it."
        exit 1
      fi
      case "$st" in
        D|D*) ;;
        S*)
          echo "not yet: state=$st. S is an interruptible sleep, which a signal ends at once, as module 01's"
          echo "         blocked pipe did. Read the State: line of /proc/<pid>/status for this one."
          exit 1 ;;
        *)
          echo "not yet: state=$st. ps -o stat or /proc/<pid>/status gives it as one letter."
          exit 1 ;;
      esac
      if [ "$w" != "$(cat /var/lib/devopslings/dstate.wchan)" ]; then
        echo "not yet: wchan=$w is not what the verifier was waiting in. /proc/<pid>/wchan holds one kernel"
        echo "         symbol; /proc/<pid>/stack shows it with the calls that led there."
        echo "         If the process is already gone, reset the lesson and read it first."
        exit 1
      fi
      if ! grep -qi 'uninterruptib' <<<"$why"; then
        echo "not yet: why= should say what kind of sleep this is. A signal is delivered when a task"
        echo "         returns to user space; what kind of kernel sleep never wakes for one?"
        exit 1
      fi

      if [ "$(dmsetup table "$dev" 2>/dev/null || true)" != "$(cat /var/lib/devopslings/dstate.table)" ]; then
        echo "not yet: the $dev mapping has been changed. Swapping in an error target makes the reads fail"
        echo "         fast and loses the volume; the path has to come back as it was."
        exit 1
      fi
      if dmsetup info "$dev" | grep -q SUSPENDED; then
        echo "not yet: $dev is still suspended, so every read of it is queued in the kernel. The"
        echo "         verifier sleeps until that I/O completes; a SIGKILL waits with it."
        exit 1
      fi
      pid=$(cat /var/lib/devopslings/dstate.pid)
      for _ in $(seq 1 20); do [ -d "/proc/$pid" ] || break; sleep 0.25; done
      if [ -d "/proc/$pid" ]; then
        echo "not yet: the stuck verifier (PID $pid) is still there, in state $(awk '/^State:/ {print $2}' /proc/$pid/status)."
        exit 1
      fi
      if systemctl is-active -q vault-verify.service; then
        systemctl stop vault-verify.service 2>/dev/null || true
      fi
      systemctl reset-failed vault-verify.service 2>/dev/null || true
      if ! timeout 60 systemctl start vault-verify.service; then
        echo "not yet: a fresh vault-verify run does not complete:"
        journalctl -u vault-verify.service -n 3 --no-pager 2>&1 | tail -3
        exit 1
      fi
      echo "PASS — the verifier slept in D at $(cat /var/lib/devopslings/dstate.wchan) on a suspended volume; with the path"
      echo "       resumed it exited, and a fresh run reads the whole volume."
---
