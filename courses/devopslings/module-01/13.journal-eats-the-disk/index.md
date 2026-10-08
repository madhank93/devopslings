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
      systemctl stop order-events.service >/dev/null 2>&1 || true
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
        sleep 0.05
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

      # Weeks of order-events history, written in seconds.
      install -d /usr/local/lib/devopslings
      cat > /usr/local/lib/devopslings/journal-fill <<'SH'
      #!/bin/sh
      read -r n tag < "/run/devopslings-fill.$1"
      awk -v n="$n" -v tag="$tag" 'BEGIN {
        srand(); for (i = 1; i <= n; i++)
          printf "order-events: processed order ORD-%06d in %dms\n", i, 10 + int(rand() * 90)
        printf "order-events: batch %s committed\n", tag }'
      # Stay alive until journald has drained the stream, so every line is
      # counted against this instance's own rate limit.
      for _ in $(seq 1 240); do
        journalctl -t order-events -n 50 -o cat | grep -c "batch $tag committed" >/dev/null && exit 0
        sleep 0.5
      done
      exit 1
      SH
      chmod 0755 /usr/local/lib/devopslings/journal-fill
      cat > /run/systemd/system/devopslings-journal-fill@.service <<'UNIT'
      [Service]
      Type=oneshot
      SyslogIdentifier=order-events
      ExecStart=/usr/local/lib/devopslings/journal-fill %i
      UNIT
      fill() {
        echo "$1 R$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')" > "/run/devopslings-fill.$2"
        systemctl start "devopslings-journal-fill@$2.service"
      }

      # Rotating at 8M while seeding leaves the history in archived files that
      # a vacuum can act on, instead of one active file nothing may touch.
      printf '[Journal]\nRateLimitIntervalSec=0\nSystemMaxFileSize=8M\n' \
        > /etc/systemd/journald.conf.d/00-seed.conf
      systemctl daemon-reload
      systemctl restart systemd-journald

      fill 260000 seed

      # A checkpoint just before hand-over, sealed into its own small archive:
      # any vacuum that keeps recent history keeps it, one that empties the
      # archives does not.
      token="CHK-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
      echo "$token" > /var/lib/devopslings/journal.checkpoint
      journalctl --rotate >/dev/null 2>&1
      echo "order-events: settlement checkpoint $token" | systemd-cat -t order-events
      fill 8000 tail
      journalctl --rotate >/dev/null 2>&1

      rm -f /etc/systemd/journald.conf.d/00-seed.conf
      systemctl restart systemd-journald
      systemctl enable order-events.service >/dev/null 2>&1 || true
      systemctl restart order-events.service >/dev/null 2>&1 || true
      sleep 2

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

      # What journald itself is enforcing, from the line it logs on every start.
      running_max=$(journalctl -u systemd-journald -o cat --no-pager 2>/dev/null \
        | grep -E '^System Journal .* max ' | tail -1 | sed -E 's/.* max ([^,]+),.*/\1/' || true)

      # 2. The journal on disk is actually under it.
      usage_mib=$(du -sm /var/log/journal 2>/dev/null | awk '{print $1}' || true)
      if [ "${usage_mib:-9999}" -gt $((mib + 4)) ]; then
        echo "not yet: /var/log/journal is still ${usage_mib}M on disk, over the ${cap} cap"
        echo "         the running journald last reported its limit as: max ${running_max:-unknown}"
        echo "         a cap in a file does nothing until journald reads it, and archived"
        echo "         journals above it stay until something vacuums them."
        exit 1
      fi

      # 3. The history is still there. The checkpoint was logged just before
      #    hand-over, so any retention that keeps recent history keeps it.
      token=$(cat /var/lib/devopslings/journal.checkpoint)
      # grep -c, not -q: an early exit SIGPIPEs journalctl and pipefail fails the test.
      kept=$(journalctl -t order-events -o cat --no-pager 2>/dev/null | grep -c "checkpoint $token" || true)
      if [ "${kept:-0}" -lt 1 ]; then
        echo "not yet: the journal is ${usage_mib}M, and the settlement checkpoint order-events"
        echo "         logged just before you took over ($token) is no longer readable."
        echo "         Under the cap is not the goal; keep the recent history and drop the old."
        exit 1
      fi

      recent=$(journalctl -u order-events.service --no-pager -o cat -n 50 2>/dev/null \
        | grep -c 'processed order' || true)
      if [ "${recent:-0}" -lt 10 ]; then
        echo "not yet: only $recent of order-events' last 50 journal lines are readable"
        echo "         the service has to keep logging into a journal you can query."
        exit 1
      fi

      # 4. It stays bounded while order-events keeps writing: a burst larger than
      #    any sensible cap must leave the total at the cap. This pushes the
      #    checkpoint out, so it is re-logged into its own archive afterwards.
      install -d /usr/local/lib/devopslings
      cat > /usr/local/lib/devopslings/journal-fill <<'SH'
      #!/bin/sh
      read -r n tag < "/run/devopslings-fill.$1"
      awk -v n="$n" -v tag="$tag" 'BEGIN {
        srand(); for (i = 1; i <= n; i++)
          printf "order-events: processed order ORD-%06d in %dms\n", i, 10 + int(rand() * 90)
        printf "order-events: batch %s committed\n", tag }'
      # Stay alive until journald has drained the stream, so every line is
      # counted against this instance's own rate limit.
      for _ in $(seq 1 240); do
        journalctl -t order-events -n 50 -o cat | grep -c "batch $tag committed" >/dev/null && exit 0
        sleep 0.5
      done
      exit 1
      SH
      chmod 0755 /usr/local/lib/devopslings/journal-fill
      cat > /run/systemd/system/devopslings-journal-fill@.service <<'UNIT'
      [Service]
      Type=oneshot
      SyslogIdentifier=order-events
      ExecStart=/usr/local/lib/devopslings/journal-fill %i
      UNIT
      systemctl daemon-reload
      fill() {
        echo "$1 R$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')" > "/run/devopslings-fill.$2"
        systemctl start "devopslings-journal-fill@$2.service"
      }

      # journald rate-limits per unit (10000 lines per 30s by default), so the
      # burst is spread across instances.
      for i in $(seq 1 16); do fill 9500 "burst$i"; done
      burst_mib=$(du -sm /var/log/journal 2>/dev/null | awk '{print $1}' || true)

      journalctl --rotate >/dev/null 2>&1
      echo "order-events: settlement checkpoint $token" | systemd-cat -t order-events
      fill 8000 tail
      journalctl --rotate >/dev/null 2>&1

      if [ "${burst_mib:-9999}" -gt $((mib + 4)) ]; then
        echo "not yet: after the check wrote ~150000 more order-events lines, /var/log/journal"
        echo "         reached ${burst_mib}M against a ${cap} cap. The running journald reports"
        echo "         max ${running_max:-unknown} — the limit journald runs with is what bounds"
        echo "         the disk, whatever the config file says."
        exit 1
      fi

      # 5. And it survives a restart of journald, which is where a runtime-only
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

      echo "PASS — SystemMaxUse=$cap in effect, /var/log/journal at ${usage_mib}M and ${burst_mib}M"
      echo "       after a burst, the pre-hand-over checkpoint still readable, and it survives"
      echo "       a restart."
---
