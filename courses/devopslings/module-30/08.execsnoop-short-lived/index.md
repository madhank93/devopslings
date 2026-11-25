---
kind: lesson
title: "load average 4, and top shows nothing above 2%"
description: |
  The box is loaded and nothing in top is using it. Every refresh shows the
  same idle daemons, because whatever is doing the work lives for a few
  milliseconds and is gone before top looks. execsnoop sees every exec as it
  happens. The work is naming the parent that spawns them and fixing the loop,
  not killing it — a timer brings it straight back.
name: execsnoop-short-lived
slug: execsnoop-short-lived
createdAt: "2026-11-23"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate ---------------------------------------------------
      systemctl stop inventory-sync.timer inventory-sync.service 2>/dev/null || true
      systemctl reset-failed inventory-sync.service 2>/dev/null || true
      rm -rf /etc/inventory /var/lib/inventory /usr/local/bin/inventory-sync \
             /etc/systemd/system/inventory-sync.service \
             /etc/systemd/system/inventory-sync.timer \
             /etc/systemd/system/timers.target.wants/inventory-sync.timer \
             /root/answers/forks.md
      install -d /root/answers /etc/inventory /var/lib/inventory
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the inventory -------------------------------------------------
      python3 - <<'PY'
      import random
      r = random.Random(7)
      roles = ["web", "api", "db", "cache", "queue", "batch", "edge", "mail"]
      sites = ["Fra1", "Ams2", "Lon1", "Dub3"]
      with open("/etc/inventory/hosts", "w") as f:
          for i in range(120):
              f.write("%s-%02d.%s.Example.NET\n" % (r.choice(roles).upper(), i, r.choice(sites)))
      PY

      # ---- the job: two command substitutions per host, every second ------
      cat > /usr/local/bin/inventory-sync <<'SH'
      #!/bin/bash
      # Normalises the host inventory into "short fqdn" pairs for the deploy
      # tooling, which re-reads hosts.txt every few seconds.
      out=/var/lib/inventory/hosts.txt
      while :; do
        : > "$out.tmp"
        while read -r h; do
          lower=$(echo "$h" | tr 'A-Z' 'a-z')
          short=$(echo "$lower" | cut -d. -f1)
          echo "$short $lower" >> "$out.tmp"
        done < /etc/inventory/hosts
        mv "$out.tmp" "$out"
        sleep 1
      done
      SH
      chmod 0755 /usr/local/bin/inventory-sync

      cat > /etc/systemd/system/inventory-sync.service <<'U'
      [Unit]
      Description=Keep the deploy inventory normalised

      [Service]
      ExecStart=/usr/local/bin/inventory-sync
      U
      cat > /etc/systemd/system/inventory-sync.timer <<'U'
      [Unit]
      Description=Restart the inventory sync if it stops

      [Timer]
      OnActiveSec=1
      OnUnitInactiveSec=15

      [Install]
      WantedBy=timers.target
      U
      systemctl daemon-reload
      systemctl enable --now inventory-sync.timer
      for _ in $(seq 30); do
        systemctl is-active -q inventory-sync.service && break
        sleep 0.5
      done
      systemctl is-active -q inventory-sync.service

      echo "scenario ready — load average is climbing; top shows nothing busy"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e
      ans=/root/answers/forks.md
      out=/var/lib/inventory/hosts.txt
      unit=inventory-sync.service
      ceiling=30
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty. Name the process that spawns the"
        echo "         short-lived commands:  parent: <name>"
        exit 1
      fi
      p=$(tr 'A-Z' 'a-z' < "$ans" | sed -n 's/^[[:space:]]*parent[[:space:]]*[:=][[:space:]]*//p' | head -n 1)
      if ! printf '%s' "$p" | grep -Eq '\binventory-sync\b'; then
        echo "not yet: parent says '${p:-nothing}'. execsnoop shows what runs;"
        echo "         counting forks by the forking process's name (Hint 1) shows who"
        echo "         starts it — the parent is the one that stays."
        exit 1
      fi

      # The timer restarts a stopped job; grading does the same rather than
      # waiting up to fifteen seconds for it.
      if ! systemctl is-active -q "$unit"; then
        if ! systemctl start "$unit" 2>/dev/null; then
          echo "not yet: $unit does not start any more. The deploy tooling still"
          echo "         needs hosts.txt kept current; fix the loop, not the job."
          exit 1
        fi
      fi
      sleep 4

      # Forks made inside the job's cgroup over five seconds. /proc/stat's
      # processes counter is host-wide, and on a shared kernel it counts every
      # container's forks too.
      cg=/sys/fs/cgroup$(cut -d: -f3 "/proc/$(systemctl show -P MainPID "$unit")/cgroup")
      fout=$(mktemp)
      timeout -s INT 9 bpftrace -e "
        tracepoint:sched:sched_process_fork /cgroup == cgroupid(\"$cg\")/ { @n = count(); }
        interval:s:5 { exit(); }" > "$fout" 2>&1 &
      bt=$!

      # Each pass replaces hosts.txt with mv, so a new inode marks a rewrite.
      # Time one full gap between rewrites: a single mtime check passes a slow
      # loop whenever it happens to land just after a pass.
      ino() { stat -c %i "$out" 2>/dev/null || echo none; }
      next_rewrite() {
        local from n=0
        from=$(ino)
        while [ "$(ino)" = "$from" ]; do
          n=$((n + 1)); [ "$n" -gt $(($1 * 5)) ] && return 1
          sleep 0.2
        done
      }
      gap_ok=1
      if ! next_rewrite 12 || ! next_rewrite 6; then gap_ok=0; fi

      wait "$bt" 2>/dev/null || true
      n=$(sed -n 's/^@n: *//p' "$fout")
      rm -f "$fout"
      : "${n:=0}"
      rate=$((n / 5))

      if ! systemctl is-active -q "$unit"; then
        echo "not yet: $unit exits on its own now. It has to keep running and"
        echo "         keep hosts.txt current."
        exit 1
      fi
      if [ "$gap_ok" = 0 ]; then
        echo "not yet: hosts.txt went more than five seconds without a rewrite. The"
        echo "         deploy tooling re-reads it every few seconds, so the job has to"
        echo "         rewrite it at least every five. Slowing the loop down hides the"
        echo "         forks by doing less work."
        exit 1
      fi
      want=$(while read -r h; do l=$(printf '%s' "$h" | tr 'A-Z' 'a-z'); echo "${l%%.*} $l"; done < /etc/inventory/hosts)
      if [ "$(cat "$out")" != "$want" ]; then
        echo "not yet: hosts.txt no longer holds a 'short fqdn' line per host,"
        echo "         lower-cased, in inventory order. The fix has to keep the output"
        echo "         identical."
        exit 1
      fi
      if [ "$rate" -gt "$ceiling" ]; then
        echo "not yet: $unit still forks about $rate processes a second (ceiling"
        echo "         $ceiling). Each \$(echo ... | tr ...) is a subshell plus a pipeline"
        echo "         of new processes, once per host per pass. bash can lower-case"
        echo "         and cut a string without starting anything."
        exit 1
      fi

      echo "PASS — inventory-sync forks about $rate processes a second (from several hundred),"
      echo "       and hosts.txt is still current and unchanged."
