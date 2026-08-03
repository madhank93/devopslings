---
kind: lesson
title: "a healthy service that takes the box down in three weeks"
description: |
  Nothing is broken. A chatty service logs steadily, journald keeps everything,
  and the only question is which week the disk fills. Capping it is four
  characters of config — capping it without throwing away the history you
  actually need is the lesson.
name: journal-eats-the-disk
slug: journal-eats-the-disk
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /var/lib/devopslings /root/answers

      # No cap anywhere. The shipped default is 10% of the filesystem, which on
      # a big disk is a lot of gigabytes and on a small one is still more than
      # anybody planned for.
      rm -f /etc/systemd/journald.conf.d/*.conf 2>/dev/null || true
      install -d /etc/systemd/journald.conf.d

      cat > /usr/local/bin/order-events <<'SH'
      #!/bin/bash
      set -euo pipefail
      i=0
      while :; do
        i=$((i + 1))
        echo "order-events: processed order ORD-$(printf '%06d' $i) in $((RANDOM % 90 + 10))ms"
        [ $((i % 200)) -eq 0 ] && echo "order-events: batch $((i / 200)) committed"
        sleep 0.002
      done
      SH
      chmod 0755 /usr/local/bin/order-events

      cat > /etc/systemd/system/order-events.service <<'UNIT'
      [Unit]
      Description=Order event stream

      [Service]
      ExecStart=/usr/local/bin/order-events
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable order-events.service >/dev/null 2>&1 || true
      systemctl restart systemd-journald >/dev/null 2>&1 || true
      systemctl restart order-events.service >/dev/null 2>&1 || true

      # Let it build a journal worth looking at. Three weeks compressed into
      # forty seconds.
      sleep 40

      journalctl --disk-usage 2>/dev/null | tail -1

      cat > /root/questions.txt <<'Q'
      order-events is healthy and journald is keeping every line it produces.

        1. Cap the journal so it cannot grow past 48M on this box, and make the
           cap survive a journald restart.
        2. Bring the journal already on disk back under that cap.
        3. Keep the recent history: the check reads back the last events
           order-events produced, so a journal you emptied entirely fails.

      order-events must still be running and still logging when you are done.
      Q

      echo "scenario ready — order-events is logging and nothing bounds the journal"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # The service is still doing its job.
      if ! systemctl is-active --quiet order-events.service; then
        echo "not yet: order-events.service is not running"
        echo "         stopping the writer bounds the journal by removing the workload,"
        echo "         which is not the same as bounding the journal."
        exit 1
      fi

      # 1. The cap is configured, and configured where journald reads it.
      # Every one of these pipelines can legitimately match nothing, and the
      # task shell runs with `set -euo pipefail` — so they end in `|| true`,
      # otherwise the check dies silently instead of explaining itself.
      cap=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -iE '^[[:space:]]*SystemMaxUse=' | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true)
      if [ -z "$cap" ]; then
        echo "not yet: no SystemMaxUse= is in effect"
        echo "         set it in /etc/systemd/journald.conf or a drop-in under"
        echo "         /etc/systemd/journald.conf.d/, then restart systemd-journald."
        exit 1
      fi

      # Normalise to MiB for comparison.
      num=$(printf '%s' "$cap" | tr -dc '0-9')
      unit=$(printf '%s' "$cap" | tr -dc 'A-Za-z' | tr 'a-z' 'A-Z')
      case "$unit" in
        ""|M) mib=$num ;;
        K)    mib=$((num / 1024)) ;;
        G)    mib=$((num * 1024)) ;;
        *)    mib=$num ;;
      esac
      if [ "${mib:-9999}" -gt 48 ]; then
        echo "not yet: SystemMaxUse is $cap, which is above the 48M the box can afford"
        exit 1
      fi

      # 2. The journal on disk is actually under it. A cap that only applies to
      #    future writes leaves the disk exactly as full as it was.
      usage_mib=$(du -sm /var/log/journal 2>/dev/null | awk '{print $1}' || true)
      if [ "${usage_mib:-9999}" -gt 60 ]; then
        echo "not yet: /var/log/journal is still ${usage_mib}M on disk"
        echo "         the setting bounds what journald writes from now on; it does not"
        echo "         retroactively remove what is already there."
        journalctl --disk-usage 2>&1 | sed 's/^/         /'
        exit 1
      fi

      # 3. The history is still there. Vacuuming to nothing satisfies every
      #    check above and destroys the reason the journal exists.
      recent=$(journalctl -u order-events.service --no-pager -o cat -n 50 2>/dev/null \
        | grep -c 'processed order' || true)
      if [ "${recent:-0}" -lt 10 ]; then
        echo "not yet: only $recent recent order-events lines are readable"
        echo "         the journal is under the cap because it is empty. A retention"
        echo "         policy has to keep something — that is what it is for."
        exit 1
      fi

      # 4. And it survives a restart of journald, which is where a runtime-only
      #    change quietly reverts.
      before=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -ciE '^[[:space:]]*SystemMaxUse=' || true)
      systemctl restart systemd-journald >/dev/null 2>&1 || true
      sleep 2
      after=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -ciE '^[[:space:]]*SystemMaxUse=' || true)
      if [ "${after:-0}" -lt 1 ] || [ "${after:-0}" != "${before:-0}" ]; then
        echo "not yet: the cap did not survive a journald restart"
        exit 1
      fi

      echo "PASS — SystemMaxUse=$cap in effect, /var/log/journal at ${usage_mib}M,"
      echo "       $recent recent order-events lines still readable, and it survives a restart."
---
