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
      { grep -lsE 'Unattended-Upgrade|APT::Periodic' /etc/apt/apt.conf.d/* || true; } | xargs -r rm -f
      rm -f /boot/vmlinuz-* /var/log/apt/history.log

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

      # The update also installed a kernel. A container runs the host's kernel,
      # so these images are placeholders; the evidence is the version mismatch.
      running=$(uname -r)
      staged=6.12.57+deb13-amd64
      for k in "$running" "$staged"; do
        echo "placeholder: kernel images are not shipped in this sandbox" > "/boot/vmlinuz-$k"
      done
      install -d /var/log/apt
      cat > /var/log/apt/history.log <<HIST

      Start-Date: 2026-08-26  10:01:47
      Commandline: /usr/bin/unattended-upgrade
      Install: linux-image-$staged:amd64 (6.12.57-1, automatic)
      Upgrade: linux-image-amd64:amd64 (6.12.48-1, 6.12.57-1), libwidget1:amd64 (1.4.2-1, 1.4.2-1+deb13u1), vim-tiny:amd64 (2:9.1.1230-2, 2:9.1.1230-2+deb13u1)
      End-Date: 2026-08-26  10:02:09
      HIST

      # Debian's shipped unattended-upgrades policy: the periodic trigger is
      # absent, and the stable point-release origin is allowed alongside security.
      cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'CONF'
      Unattended-Upgrade::Origins-Pattern {
      //      "origin=Debian,codename=${distro_codename}-updates";
      //      "origin=Debian,codename=${distro_codename}-proposed-updates";
              "origin=Debian,codename=${distro_codename},label=Debian";
              "origin=Debian,codename=${distro_codename},label=Debian-Security";
              "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
      };

      Unattended-Upgrade::Package-Blacklist {
      };

      // Unattended-Upgrade::Automatic-Reboot "false";
      // Unattended-Upgrade::Automatic-Reboot-Time "02:00";
      CONF

      # Write questions file
      cat > /root/questions.txt <<'Q'
      The overnight security run installed three updates (see
      /var/log/apt/history.log), including the fix for libwidget. The file on disk is
      the fixed version:

        $ ls -l /opt/patchlab/libwidget.so.1

      This box runs a service that cannot take unplanned downtime. Three jobs:

      1. Services. A process maps a shared library when it starts and keeps that copy
         until it restarts, so a service that was already running may still be
         executing the old code. Find every running service that still has the
         pre-patch libwidget mapped (/proc/<pid>/maps shows what a process has
         mapped, /proc/<pid>/cgroup which unit it belongs to) and restart just those.
         Other services are running too; restart only what needs it. Do not reboot.

      2. Reboot. Of the updates in that transaction, decide which one does not take
         effect until the machine reboots, from what is running versus what is
         installed. (This is a container: its running kernel is the host's, and the
         images in /boot are placeholders. The version comparison is the real part.)

      3. Policy. Security fixes should keep landing without a human, and nothing
         else should. /etc/apt/apt.conf.d/50unattended-upgrades is Debian's shipped
         policy. Make apt's configuration run unattended upgrades daily, from the
         security archive only, and never reboot the box on its own.
         `apt-config dump` shows what apt (and unattended-upgrades) will read.
         The unattended-upgrades package itself is not installed in this offline
         sandbox; the policy is ordinary apt configuration and is graded as such.

      Then write /root/answers/patch.md with exactly three lines:

        stale_library: <the library still mapped from memory after the patch>
        found_with: <the marker in /proc/<pid>/maps that flags a stale mapping>
        reboot_required: <the package from the transaction that needs a reboot>
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

      # The unattended policy, read through apt's own parser: that is what
      # unattended-upgrades loads, so a file that merely looks right is not enough.
      if ! dump=$(apt-config dump 2>&1); then
        echo "not yet: apt cannot parse its configuration, so unattended-upgrades"
        echo "         would not run at all:"
        printf '%s\n' "$dump" | grep '^E:' | sed 's/^/         /' || true
        exit 1
      fi
      eval "$(apt-config shell period APT::Periodic::Unattended-Upgrade period_i APT::Periodic::Unattended-Upgrade/i reboot Unattended-Upgrade::Automatic-Reboot/b)"
      if [ "${period_i:-0}" -lt 1 ] && [ "${period:-}" != "always" ]; then
        echo "not yet: APT::Periodic::Unattended-Upgrade is '${period:-unset}'. Until it is"
        echo "         a number of days (\"1\" = daily), the unattended run never fires."
        exit 1
      fi
      origins=$(printf '%s\n' "$dump" | sed -nE 's/^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins):: "(.*)";$/\2/Ip')
      if [ -z "$origins" ]; then
        echo "not yet: no Origins-Pattern or Allowed-Origins entries survive in apt's"
        echo "         configuration, so an unattended run would apply nothing, security"
        echo "         fixes included."
        exit 1
      fi
      other=$(printf '%s\n' "$origins" | grep -iv 'security' || true)
      if [ -n "$other" ]; then
        echo "not yet: unattended upgrades may still install from an origin that is not"
        echo "         the security archive:"
        printf '%s\n' "$other" | sed 's/^/           /'
        echo "         Every update from there lands unattended too, not just security fixes."
        exit 1
      fi
      if [ "${reboot:-}" = "true" ]; then
        echo "not yet: Unattended-Upgrade::Automatic-Reboot is on. The box would reboot"
        echo "         itself whenever an update asks for one: the unplanned downtime"
        echo "         this service cannot take."
        exit 1
      fi

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/patch.md is missing or empty."
        echo "         Three lines: stale_library, found_with and reboot_required."
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

      # The one update that needs a reboot is the kernel the transaction installed;
      # the library and the unused binary need a restart or nothing.
      a_boot=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*reboot_required[[:space:]]*[:=][[:space:]]*//p' | head -1)
      if printf '%s' "$a_boot" | grep -Eq '\b(libwidget|vim)'; then
        echo "not yet: reboot_required says '$a_boot'. A library or program update takes"
        echo "         effect when the processes using it restart; no reboot is needed."
        exit 1
      fi
      if ! printf '%s' "$a_boot" | grep -Eq '\blinux-image\b'; then
        echo "not yet: reboot_required says '${a_boot:-nothing}'. Name the package from"
        echo "         the transaction in /var/log/apt/history.log that only takes effect"
        echo "         after a reboot. Compare uname -r with what the update put in /boot."
        exit 1
      fi

      echo "PASS — the affected services run the patched library, the kernel is the one"
      echo "       update left for a planned reboot, and only security fixes land unattended."
