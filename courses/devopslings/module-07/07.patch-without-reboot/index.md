---
kind: lesson
title: "the library is patched on disk and still running in memory"
description: |
  A shared library got its security update and the file on disk is fixed — but
  every service that was already running still has the old copy mapped into
  memory, marked (deleted), still executing the vulnerable code. Rebooting fixes
  it and takes everything down with it. The skill is finding exactly which
  processes hold the stale mapping and restarting only those.
name: patch-without-reboot
slug: patch-without-reboot
createdAt: "2026-08-26"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # Idempotent teardown
      systemctl stop widget.service cache.service metrics.service 2>/dev/null || true
      rm -f /etc/systemd/system/widget.service /etc/systemd/system/cache.service /etc/systemd/system/metrics.service
      rm -rf /opt/patchlab /root/answers/patch.md
      systemctl daemon-reload 2>/dev/null || true
      systemctl reset-failed widget.service cache.service metrics.service 2>/dev/null || true

      # Create the answers dir and the library directory, then make the shared library
      install -d /root/answers /opt/patchlab
      src=$(find /lib /usr/lib -name 'libz.so.1' 2>/dev/null | head -1)
      cp "$src" /opt/patchlab/libwidget.so.1

      # Write the program that keeps the library mapped
      cat > /opt/patchlab/hold.py <<'PY'
      import ctypes, time
      ctypes.CDLL("/opt/patchlab/libwidget.so.1")
      while True:
          time.sleep(3600)
      PY

      # Write three unit files
      for svc in widget cache; do
        cat > /etc/systemd/system/$svc.service <<UNIT
      [Unit]
      Description=$svc daemon
      [Service]
      ExecStart=/usr/bin/python3 /opt/patchlab/hold.py
      UNIT
      done

      cat > /etc/systemd/system/metrics.service <<'UNIT'
      [Unit]
      Description=metrics daemon
      [Service]
      ExecStart=/usr/bin/python3 -c "import time; time.sleep(1000000)"
      UNIT

      # Reload systemd and start all three
      systemctl daemon-reload
      systemctl start widget.service cache.service metrics.service

      # Apply the "patch"
      sleep 1
      cp "$src" /opt/patchlab/libwidget.so.1.new
      mv /opt/patchlab/libwidget.so.1.new /opt/patchlab/libwidget.so.1

      # Write questions file
      cat > /root/questions.txt <<'Q'
      The security update for libwidget is installed. The file on disk is the fixed
      version:

        $ ls -l /opt/patchlab/libwidget.so.1

      But a patched file on disk is not a patched running system. A process maps a
      shared library into memory when it starts and keeps that copy until it restarts,
      so every service that was already running is still executing the OLD, vulnerable
      code. The kernel marks the mapping (deleted): the file it points to no longer
      exists on disk.

      Find every running service that still has the old libwidget mapped, and restart
      just those. Do not reboot the box — a reboot works, but it is the blunt
      instrument that takes down everything to fix a few processes, and on a real
      server "just reboot it" is the gamble you are trying to avoid.

      The mappings a process holds are listed in /proc/<pid>/maps, and a stale one is
      marked (deleted):

        $ grep -l '(deleted)' /proc/*/maps
        $ grep libwidget /proc/<pid>/maps

      Map a pid back to its service with:

        $ cat /proc/<pid>/cgroup        # ends in <name>.service

      Two services are affected; a third is running but never loaded the library, and
      does not need restarting. Restart only what actually needs it.

      Then write /root/answers/patch.md with exactly two lines:

        stale_library: <the library still mapped from memory after the patch>
        found_with: <the marker in /proc/<pid>/maps that flags a stale mapping>
      Q

      echo "scenario ready — libwidget patched on disk, two services still running the old copy"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/patch.md

      # Any process still holding the pre-patch libwidget has it as a (deleted)
      # mapping. Scan every process; a hit means a service is still running the
      # old code and has not been restarted. This is exactly what needrestart
      # automates, done by hand so the signal is visible.
      stale=""
      for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        if grep -sqE 'libwidget.*\(deleted\)' "/proc/$p/maps" 2>/dev/null; then
          unit=$(tr '\0' '\n' < "/proc/$p/cgroup" 2>/dev/null | grep -oE '[a-zA-Z0-9_-]+\.service' | tail -1)
          stale="$stale ${unit:-pid-$p}"
        fi
      done

      if [ -n "$stale" ]; then
        echo "not yet: still running the pre-patch libwidget:$stale"
        echo "         Each of these mapped the old library before it was replaced"
        echo "         and is still executing it. Restart them so they map the"
        echo "         patched file: systemctl restart <name>"
        exit 1
      fi

      # The two services that needed the restart have to still be up — the fix is
      # to restart them, not to stop them.
      for svc in widget cache; do
        if [ "$(systemctl is-active $svc.service 2>/dev/null)" != "active" ]; then
          echo "not yet: $svc.service is not active. It needed restarting, not"
          echo "         stopping — it should be running the patched library now."
          exit 1
        fi
      done

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/patch.md is missing or empty."
        echo "         Two lines: stale_library and found_with."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_lib=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*stale_library[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_found=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*found_with[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_lib" | grep -q 'libwidget'; then
        echo "not yet: stale_library says '${a_lib:-nothing}'. Name the library that"
        echo "         was patched on disk but still mapped in memory."
        exit 1
      fi
      if ! printf '%s' "$a_found" | grep -q 'deleted'; then
        echo "not yet: found_with says '${a_found:-nothing}'. Name the marker the"
        echo "         kernel puts on a mapping whose file has been replaced."
        exit 1
      fi

      echo "PASS — both affected services restarted onto the patched library, the"
      echo "       decoy was left alone, and nothing is running deleted code."
