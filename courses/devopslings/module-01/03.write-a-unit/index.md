---
kind: lesson
title: "a working script and nobody to start it"
description: |
  stock-feed runs fine when you run it. It needs to start at boot, come back
  when it exits, and not start before the cache it depends on — none of which a
  script in /usr/local/bin can do for itself. Write the unit. The check proves
  all three by doing them, not by reading the file.
name: write-a-unit
slug: write-a-unit
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/stock /var/lib/devopslings

      # The dependency: a warm-up that takes about four seconds and then stays
      # "active (exited)". Type=oneshot with RemainAfterExit is what makes
      # After= mean something here — a Type=simple unit counts as started the
      # instant it forks, so ordering against one would not make anybody wait.
      cat > /usr/local/bin/stock-cache-warm <<'SH'
      #!/bin/bash
      set -euo pipefail
      rm -f /run/stock-cache.ready
      sleep 4
      : > /run/stock-cache.ready
      echo "stock-cache: warm"
      SH
      chmod 0755 /usr/local/bin/stock-cache-warm

      cat > /etc/systemd/system/stock-cache.service <<'UNIT'
      [Unit]
      Description=Stock price cache warm-up

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/stock-cache-warm

      [Install]
      WantedBy=multi-user.target
      UNIT

      # The thing you have to wrap. It refuses to start without its cache,
      # which makes ordering observable, and it exits 0 on SIGTERM, which makes
      # the difference between Restart=on-failure and Restart=always
      # observable too.
      cat > /usr/local/bin/stock-feed <<'SH'
      #!/bin/bash
      set -euo pipefail
      if [ ! -e /run/stock-cache.ready ]; then
        echo "stock-feed: stock-cache is not ready — refusing to start" >&2
        exit 69
      fi
      echo "stock-feed: started"
      trap 'echo "stock-feed: terminated cleanly"; exit 0' TERM
      while :; do
        date -Is > /srv/stock/last-tick
        sleep 1
      done
      SH
      chmod 0755 /usr/local/bin/stock-feed

      rm -f /etc/systemd/system/stock-feed.service /srv/stock/last-tick
      systemctl daemon-reload
      systemctl enable stock-cache.service >/dev/null 2>&1 || true
      systemctl start stock-cache.service >/dev/null 2>&1 || true

      cat > /root/questions.txt <<'Q'
      Write /etc/systemd/system/stock-feed.service so that stock-feed:

        1. runs /usr/local/bin/stock-feed
        2. starts automatically at boot
        3. is restarted automatically whenever it exits — including when it
           exits successfully
        4. is never started before stock-cache.service has finished

      Then enable and start it. Nothing else on the box needs to change.
      Q

      echo "scenario ready — /usr/local/bin/stock-feed works when you run it, and nothing starts it"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      unit=/etc/systemd/system/stock-feed.service

      if [ ! -f "$unit" ]; then
        echo "not yet: $unit does not exist"
        exit 1
      fi
      systemctl daemon-reload

      # 1. It runs, and it runs the right thing.
      if ! systemctl is-active --quiet stock-feed.service; then
        echo "not yet: stock-feed.service is not active"
        systemctl --no-pager --lines=5 status stock-feed.service 2>&1 | tail -6
        exit 1
      fi
      if [ ! -s /srv/stock/last-tick ]; then
        echo "not yet: the unit is active but /srv/stock/last-tick is empty — it is"
        echo "         running something, but not the feed."
        exit 1
      fi

      # 2. It survives a reboot.
      if ! systemctl is-enabled --quiet stock-feed.service; then
        echo "not yet: stock-feed.service is not enabled, so a reboot loses it."
        echo "         'systemctl enable' needs an [Install] section to make its symlink."
        exit 1
      fi

      # 3. It comes back after a CLEAN exit. SIGTERM to the process itself —
      #    not 'systemctl stop', which is an instruction to stay stopped — makes
      #    the feed exit 0. Restart=on-failure does not cover that; only
      #    Restart=always does.
      before=$(systemctl show -p MainPID --value stock-feed.service)
      if [ -z "$before" ] || [ "$before" = "0" ]; then
        echo "not yet: could not read stock-feed's main PID"
        exit 1
      fi
      kill -TERM "$before" 2>/dev/null || true

      back=""
      for _ in $(seq 1 60); do
        sleep 0.5
        now=$(systemctl show -p MainPID --value stock-feed.service 2>/dev/null || echo 0)
        if systemctl is-active --quiet stock-feed.service && [ -n "$now" ] && [ "$now" != "0" ] && [ "$now" != "$before" ]; then
          back=$now; break
        fi
      done
      if [ -z "$back" ]; then
        echo "not yet: stock-feed exited cleanly (PID $before) and did not come back"
        echo "         Restart=on-failure only covers non-zero exits and signals. The"
        echo "         requirement is that it restarts whatever the exit status."
        systemctl --no-pager --lines=5 status stock-feed.service 2>&1 | tail -6
        exit 1
      fi

      # 4. Ordering, tested from cold. Without After=, the feed starts while the
      #    cache is still warming, logs 'refusing to start' and exits 69 —
      #    Restart= would eventually paper over it, so the check looks for the
      #    failed attempt rather than the eventual success.
      systemctl stop stock-feed.service  >/dev/null 2>&1 || true
      systemctl stop stock-cache.service >/dev/null 2>&1 || true
      rm -f /run/stock-cache.ready /srv/stock/last-tick
      systemctl reset-failed stock-feed.service stock-cache.service >/dev/null 2>&1 || true

      sleep 1
      since=$(date '+%Y-%m-%d %H:%M:%S')
      sleep 1

      systemctl start --no-block stock-cache.service >/dev/null 2>&1 || true
      systemctl start --no-block stock-feed.service  >/dev/null 2>&1 || true

      ok=""
      for _ in $(seq 1 80); do
        sleep 0.5
        if systemctl is-active --quiet stock-feed.service && [ -s /srv/stock/last-tick ]; then
          ok=yes; break
        fi
      done
      if [ -z "$ok" ]; then
        echo "not yet: started from cold, stock-feed never came up"
        journalctl -u stock-feed.service --no-pager -o cat --since "$since" 2>&1 | tail -5 | sed 's/^/         /'
        exit 1
      fi

      raced=$(journalctl -u stock-feed.service --no-pager -o cat --since "$since" 2>/dev/null \
        | grep -c 'refusing to start' || true)
      if [ "${raced:-0}" -gt 0 ]; then
        echo "not yet: stock-feed is up, but it got there by failing first —"
        echo "         it tried to start $raced time(s) before stock-cache was ready:"
        echo "           stock-feed: stock-cache is not ready — refusing to start"
        echo "         Restart= is hiding the race rather than removing it. Order the"
        echo "         unit after stock-cache.service so the first attempt is the one"
        echo "         that works."
        exit 1
      fi

      echo "PASS — enabled, running, restarted after a clean exit, and it waited for stock-cache."
---
