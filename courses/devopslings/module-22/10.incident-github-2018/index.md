---
kind: lesson
title: "Replay: GitHub, October 2018"
description: |
  Forty-three seconds of network partition, a database failover that
  worked exactly as designed, and twenty-four hours of putting the data back
  together. Replay it on pg1 and pg2: find out what the two sides disagree
  about, then write the failback that brings the shop home without losing
  either side's orders.
name: incident-github-2018
slug: incident-github-2018
createdAt: "2026-10-16"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      # How many orders each side takes while they are apart. Fixed for this
      # scenario, so verify can replay exactly the same divergence.
      draw=$RANDOM
      echo "$draw" > /root/.github-2018-draw
      cat > /root/.github-2018-stage <<'SH'
      # stage <draw> — pg1 primary with pg2 streaming, then the divergence.
      set -eu
      draw=$1
      east=$((20 + draw % 25))
      west=$((50 + (draw / 25) % 25))
      Q() { psql -h "$1" -qtAX -v ON_ERROR_STOP=1 "${@:2}"; }
      streaming() { [ "$(Q pg1 -c "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'" 2>/dev/null)" = 1 ]; }

      for _ in $(seq 60); do pg_isready -q -h pg1 && break; sleep 1; done
      [ "$(Q pg1 -c 'select pg_is_in_recovery()')" = f ] || Q pg1 -c 'select pg_promote(wait => true)' >/dev/null
      Q pg1 -c "ALTER SYSTEM RESET synchronous_standby_names" -c "ALTER SYSTEM RESET default_transaction_read_only" -c "SELECT pg_reload_conf()" >/dev/null
      cp /defaults/app.env /ha/app.env
      if ! streaming || [ "$(Q pg2 -c 'select pg_is_in_recovery()' 2>/dev/null)" != t ]; then
        mkdir -p /ha/pg2 && touch /ha/pg2/reclone
        docker restart devopslings-ha-pg2 >/dev/null
        for _ in $(seq 120); do streaming && break; sleep 1; done
        streaming || { echo "stage: pg2 did not come back as a standby of pg1" >&2; exit 1; }
      fi
      Q pg1 -c "DELETE FROM orders WHERE reference LIKE 'gh-%'" \
        -c "SELECT setval('orders_id_seq', (SELECT max(id) FROM orders))" >/dev/null
      lsn=$(Q pg1 -c 'select pg_current_wal_lsn()')
      for _ in $(seq 60); do
        [ "$(Q pg2 -c "select pg_last_wal_replay_lsn() >= '$lsn'")" = t ] && break
        sleep 0.5
      done

      # 22:52 UTC: the partition. The orchestrator, on the far side of it,
      # cannot see pg1 and promotes pg2.
      Q pg2 -c 'select pg_promote(wait => true)' >/dev/null
      # Writes pg1 accepted before the app was moved. pg2 never receives them.
      Q pg1 -c "INSERT INTO orders (reference) SELECT 'gh-east-' || g FROM generate_series(1, $east) g"
      # The app follows the orchestrator to pg2 and keeps taking orders there.
      sed -i 's/host=pg1/host=pg2/' /ha/app.env
      Q pg2 -c "INSERT INTO orders (reference) SELECT 'gh-west-' || g FROM generate_series(1, $west) g"
      SH
      bash /root/.github-2018-stage "$draw"

      cat > /ha/answers/github-2018.txt <<'TXT'
      # Compare the orders tables on pg1 and pg2. Count, don't estimate.
      #
      # orders that exist only on pg1:
      only_on_pg1: ?
      # orders that exist only on pg2:
      only_on_pg2: ?
      # ids that both servers have used, for two different orders:
      same_id_both: ?
      TXT
      cat > /ha/failback.sh <<'SH'
      #!/bin/bash
      # Run from ops. Afterwards: pg1 is the primary and the app uses it, every
      # order either server took is on it exactly once, and pg2 is a streaming
      # standby of pg1 again.
      set -eu
      echo "failback: not written yet" >&2
      exit 1
      SH
      chmod +x /ha/failback.sh
      for _ in $(seq 20); do curl -fsS --max-time 2 http://www/db >/dev/null 2>&1 && break; sleep 0.5; done

      echo "scenario ready — pg2 was promoted during a partition, and pg1 kept taking writes:"
      echo
      for h in pg1 pg2; do
        psql -h "$h" -tAXc "select '$h: in recovery=' || pg_is_in_recovery() || ', ' || count(*) || ' orders, newest id ' || max(id) from orders"
      done
      echo "app: $(curl -s http://www/db)"
      echo
      echo "  your reconstruction:  /ha/answers/github-2018.txt"
      echo "  your failback:        /ha/failback.sh"
      echo "  rebuild pg2 from pg1: touch /ha/pg2/reclone; docker restart devopslings-ha-pg2"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 480
    run: |
      draw=$(cat /root/.github-2018-draw 2>/dev/null || true)
      if [ ! -f /root/.github-2018-stage ] || [ -z "$draw" ]; then
        echo "not yet: this scenario's setup is missing from ops. Reset the lesson to replay the partition."
        exit 1
      fi
      east=$((20 + draw % 25))
      west=$((50 + (draw / 25) % 25))
      same=$((east < west ? east : west))
      Q() { psql -h "$1" -qtAX "${@:2}"; }
      ans() { awk -F: -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" { gsub(/[^0-9]/, "", $2); print $2; exit }' /ha/answers/github-2018.txt 2>/dev/null || true; }

      a1=$(ans only_on_pg1); a2=$(ans only_on_pg2); a3=$(ans same_id_both)
      if [ -z "$a1" ] || [ -z "$a2" ] || [ -z "$a3" ]; then
        echo "not yet: /ha/answers/github-2018.txt needs a number for only_on_pg1, only_on_pg2 and same_id_both."
        exit 1
      fi
      if [ "$a1" != "$east" ] || [ "$a2" != "$west" ]; then
        echo "not yet: only_on_pg1=$a1 and only_on_pg2=$a2 do not match the two servers."
        if [ "$a1" = "$west" ] && [ "$a2" = "$east" ]; then
          echo "         They are the right two numbers the wrong way round."
        else
          echo "         An order is the same order on both sides only if it has the same id and the same"
          echo "         reference. Everything from before the partition is on both."
        fi
        exit 1
      fi
      if [ "$a3" != "$same" ]; then
        echo "not yet: same_id_both=$a3. Count the ids that appear on both servers with a different"
        echo "         reference: both sides kept handing out ids from the same sequence after they split."
        exit 1
      fi
      echo "reconstruction: $east orders only on pg1, $west only on pg2, $same ids used twice"

      if [ ! -s /ha/failback.sh ]; then
        echo "not yet: /ha/failback.sh is missing or empty."
        exit 1
      fi
      # The failback acts on the servers, so it gets the same divergence every time.
      if ! out=$(bash /root/.github-2018-stage "$draw" 2>&1); then
        echo "not yet: could not replay the partition before running your failback:"
        tail -5 <<<"$out" | sed 's/^/         | /'
        echo "         If pg1 or pg2 is wedged, reset the lesson."
        exit 1
      fi
      echo "partition replayed: app on pg2, $east orders only on pg1, $west only on pg2"
      before=$(Q pg1 -c "select count(*) from orders where reference not like 'gh-%'")

      # Customers keep ordering while the failback runs. An order they were told
      # succeeded has to survive it; one refused while pg2 is fenced is fine.
      live=$(mktemp -d)
      trap 'touch "$live/stop"' EXIT
      for c in 1 2 3 4; do
        (
          i=0
          while [ ! -e "$live/stop" ]; do
            i=$((i + 1))
            curl -fsS -o /dev/null --max-time 3 -X POST "http://www/orders?ref=gh-live-$c-$i" 2>/dev/null \
              && echo "gh-live-$c-$i" >> "$live/acked-$c"
            sleep 0.05
          done
        ) &
      done
      sleep 1

      rc=0
      timeout 240 bash /ha/failback.sh > /tmp/failback.log 2>&1 || rc=$?
      sleep 1
      touch "$live/stop"
      wait
      if [ "$rc" -ne 0 ]; then
        echo "not yet: /ha/failback.sh exited $rc. Its last lines:"
        tail -5 /tmp/failback.log | sed 's/^/         | /'
        exit 1
      fi

      if [ "$(Q pg1 -c 'select pg_is_in_recovery()' 2>/dev/null)" != f ]; then
        echo "not yet: after failback.sh, pg1 is not a writable primary."
        exit 1
      fi
      server=$(curl -fsS --max-time 8 http://www/db 2>/dev/null | jq -r .server 2>/dev/null || true)
      if [ "$server" != 172.29.23.31 ]; then
        echo "not yet: after failback.sh the app is using ${server:-no database} (pg1 is 172.29.23.31)."
        exit 1
      fi
      counts=$(Q pg1 -c "select count(*) filter (where reference like 'gh-east-%'),
                                count(distinct reference) filter (where reference like 'gh-east-%'),
                                count(*) filter (where reference like 'gh-west-%'),
                                count(distinct reference) filter (where reference like 'gh-west-%')
                         from orders")
      IFS='|' read -r e ed w wd <<<"$counts"
      if [ "$e" != "$east" ] || [ "$ed" != "$east" ]; then
        echo "not yet: pg1 should hold the $east orders it took during the partition, once each; it has $e ($ed distinct)."
        exit 1
      fi
      if [ "$wd" != "$west" ]; then
        echo "not yet: of the $west orders pg2 took after it was promoted, pg1 has $wd."
        if [ "$wd" = $((west - same)) ]; then
          echo "         The missing $same are exactly the ones whose id pg1 had already given to one of its own"
          echo "         orders. Copying a row with its id drops it, or overwrites a different order."
        elif [ "$wd" = 0 ]; then
          echo "         Making pg2 a copy of pg1 again overwrote everything pg2 took on its own."
        fi
        exit 1
      fi
      if [ "$w" != "$west" ]; then
        echo "not yet: pg1 has $w rows for the $west orders pg2 took: some are there twice."
        exit 1
      fi
      lost=$(comm -23 <(cat "$live"/acked-* 2>/dev/null | sort -u) \
        <(Q pg1 -c "select reference from orders where reference like 'gh-live-%'" | sort -u) | wc -l | tr -d ' ')
      if [ "$lost" -gt 0 ]; then
        acked=$(cat "$live"/acked-* 2>/dev/null | wc -l | tr -d ' ')
        echo "not yet: while failback.sh ran, customers placed $acked orders through www and were told each one"
        echo "         succeeded. $lost of them are not on pg1. They reached pg2 after your script copied it"
        echo "         and before the app moved, and pg2 was then rebuilt over them. Stop pg2 accepting"
        echo "         writes before you copy from it."
        exit 1
      fi
      after=$(Q pg1 -c "select count(*) from orders where reference not like 'gh-%'")
      if [ "$after" -gt "$before" ]; then
        echo "not yet: pg1 had $before orders from before the partition and now has $after. Those orders were"
        echo "         already on both servers; copying them from pg2 gave $((after - before)) of them a second id."
        exit 1
      elif [ "$after" -lt "$before" ]; then
        echo "not yet: pg1 had $before orders from before the partition and now has $after. The failback"
        echo "         removed orders that both servers agreed on."
        exit 1
      fi
      echo "pg1 is primary, the app uses it, and it holds all $east + $west orders once each"

      if ! curl -fsS -o /dev/null --max-time 8 -X POST 'http://www/orders?ref=after-failback'; then
        echo "not yet: an order through www failed after the failback."
        exit 1
      fi
      ok=""
      for _ in $(seq 60); do
        [ "$(Q pg1 -c "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'" 2>/dev/null)" = 1 ] \
          && [ "$(Q pg2 -c 'select pg_is_in_recovery()' 2>/dev/null)" = t ] && { ok=1; break; }
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "not yet: pg2 is not streaming from pg1. It has a history of its own since it was promoted,"
        echo "         so it cannot just start following pg1 again: it has to be rebuilt from pg1."
        exit 1
      fi
      lsn=$(Q pg1 -c 'select pg_current_wal_lsn()')
      for _ in $(seq 30); do
        [ "$(Q pg2 -c "select pg_last_wal_replay_lsn() >= '$lsn'")" = t ] && break
        sleep 0.5
      done
      if [ "$(Q pg2 -c "select count(*) from orders where reference like 'gh-east-%' or reference like 'gh-west-%'")" != $((east + west)) ]; then
        echo "not yet: pg2 is streaming from pg1 but does not have the merged orders."
        exit 1
      fi
      echo "pg2 is a standby of pg1 again, with every order"
      echo
      echo "PASS — failed back with both sides' orders, and nobody's order was given away."
