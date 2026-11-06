---
kind: lesson
title: "Promote the replica, lose nothing"
description: |
  pg1 is gone and pg2 is a read-only copy. Write the failover that promotes
  pg2 and moves the shop onto it — and make sure every order the shop told a
  customer was placed is still there afterwards.
name: replica-promotion
slug: replica-promotion
createdAt: "2026-10-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      cat > /ha/failover.sh <<'SH'
      #!/bin/bash
      # Run from ops once pg1 is dead. Afterwards the shop must take orders
      # again, on a database that has every order it ever confirmed.
      set -eu
      echo "failover: not written yet" >&2
      exit 1
      SH
      chmod +x /ha/failover.sh
      for _ in $(seq 20); do curl -fsS --max-time 1 http://www/ >/dev/null 2>&1 && break; sleep 0.5; done
      echo "scenario ready — pg1 takes every write, and pg2 streams a copy:"
      echo
      psql -h pg1 -c "select application_name, state, sync_state from pg_stat_replication"
      psql -h pg2 -tAc "select 'pg2 in recovery (read-only): ' || pg_is_in_recovery()"
      echo
      echo "  the failover you write:    /ha/failover.sh"
      echo "  the app's database:        DB_DSN in /ha/app.env"
      echo "  the two servers:           psql -h pg1 / psql -h pg2"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      work=$(mktemp -d)
      cp /ha/app.env "$work/app.env"
      restore() {
        node heal pg2 back >/dev/null 2>&1 || true
        cp "$work/app.env" /ha/app.env
        docker start devopslings-ha-pg1 >/dev/null 2>&1 || true
        for _ in $(seq 60); do pg_isready -q -h pg1 && break; sleep 1; done
        if [ "$(psql -h pg1 -tAXc "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'" 2>/dev/null)" != 1 ] \
           || [ "$(psql -h pg2 -tAXc 'select pg_is_in_recovery()' 2>/dev/null)" != t ]; then
          mkdir -p /ha/pg2 && touch /ha/pg2/reclone
          docker restart devopslings-ha-pg2 >/dev/null
          for _ in $(seq 90); do
            [ "$(psql -h pg1 -tAXc "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'" 2>/dev/null)" = 1 ] && break
            sleep 1
          done
          # A clone copies pg1's settings; a standby has no use for sync ones.
          psql -h pg2 -qtAXc "ALTER SYSTEM RESET synchronous_standby_names" -c "SELECT pg_reload_conf()" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      # Start from pg1 primary and pg2 streaming from it; restore also runs on exit.
      restore
      work=$(mktemp -d)
      cp /ha/app.env "$work/app.env"
      trap restore EXIT

      if [ ! -s /ha/failover.sh ]; then
        echo "not yet: /ha/failover.sh is missing or empty."
        exit 1
      fi
      ssn=$(psql -h pg1 -tAXc 'show synchronous_standby_names')
      sc=$(psql -h pg1 -tAXc 'show synchronous_commit')
      if ! curl -fsS -o /dev/null --max-time 8 -X POST 'http://www/orders?ref=probe'; then
        echo "not yet: with pg1 and pg2 both up, an order through www did not complete in 8s."
        if [ -n "$ssn" ]; then
          echo "pg1 has synchronous_standby_names = '$ssn', and the standbys connected to it are:"
          psql -h pg1 -tAXc "select '  application_name=' || application_name || ' state=' || state from pg_stat_replication" || true
          echo "A commit waits for a standby matching that name. If none matches, it waits forever."
        fi
        exit 1
      fi

      # Orders are acknowledged while pg2 is cut off; then pg1 dies.
      run=$(date +%s)
      : > "$work/acked"
      ( i=0
        while [ ! -f "$work/stop" ]; do
          i=$((i + 1))
          if curl -fsS -o /dev/null --max-time 8 -X POST "http://www/orders?ref=grader-$run-$i" 2>/dev/null; then
            echo "grader-$run-$i" >> "$work/acked"
          fi
          sleep 0.1
        done ) &
      writer=$!
      sleep 2
      node cut pg2 back >/dev/null
      sleep 3
      docker kill devopslings-ha-pg1 >/dev/null
      node heal pg2 back >/dev/null
      touch "$work/stop"
      wait "$writer" 2>/dev/null || true
      acked=$(wc -l < "$work/acked")
      echo "pg1 killed after $acked acknowledged orders; running /ha/failover.sh"

      fo_rc=0
      timeout 90 bash /ha/failover.sh > "$work/fo.log" 2>&1 || fo_rc=$?
      if [ "$fo_rc" -ne 0 ]; then
        echo "not yet: /ha/failover.sh exited $fo_rc. Its last lines:"
        tail -5 "$work/fo.log" | sed 's/^/         | /'
        exit 1
      fi

      ok=""
      for _ in $(seq 20); do
        if out=$(curl -fsS --max-time 8 -X POST 'http://www/orders?ref=after-failover' 2>&1); then ok=1; break; fi
        sleep 1
      done
      if [ -z "$ok" ]; then
        err=$(curl -s --max-time 8 -X POST 'http://www/orders?ref=after-failover' || true)
        rec=$(psql -h pg2 -tAXc 'select pg_is_in_recovery()' 2>/dev/null || echo unknown)
        echo "not yet: 20 seconds after failover.sh finished, orders through www still fail:"
        echo "         | $err"
        if [ "$rec" = t ]; then
          echo "pg2 is still in recovery: a standby, read-only. Nothing promoted it."
        elif grep -Eq '^DB_DSN=.*host=pg1([^,]|$)' /ha/app.env; then
          echo "pg2 has been promoted, but /ha/app.env still sends the app to host=pg1, which is dead."
        elif [ -n "$(psql -h pg2 -tAXc 'show synchronous_standby_names' 2>/dev/null)" ]; then
          echo "pg2 is a primary with synchronous_standby_names set, and no standby: every commit waits."
        fi
        exit 1
      fi
      echo "after failover: orders accepted again"

      missing=$(while read -r ref; do
        [ "$(psql -h pg2 -tAXc "select count(*) from orders where reference = '$ref'")" = 1 ] || echo "$ref"
      done < "$work/acked")
      if [ -n "$missing" ]; then
        echo "not yet: $(wc -l <<<"$missing") of $acked orders the shop confirmed are not on pg2, e.g. $(head -1 <<<"$missing")."
        echo "They were committed on pg1 and confirmed to the customer while pg2 was cut off,"
        echo "and pg1 died before it could send them."
        echo "pg1 had synchronous_standby_names = '${ssn}' and synchronous_commit = '$sc'."
        exit 1
      fi
      echo "all $acked confirmed orders are on the new primary"
      echo
      echo "PASS — pg2 took over, and no confirmed order was lost."
