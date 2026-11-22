---
kind: lesson
title: "Eighty connections, fewer tickets"
description: |
  At the last on-sale, bookings queued in pgbouncer, so the pool went from 20
  to 80 server connections. This on-sale is worse: one booking in twenty
  takes longer than the app will wait, and the box office sells fewer seats
  a second than before. Measure the pool, size it from what you measure, and
  get the errors to zero.
name: pool-sizing
slug: pool-sizing
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: db-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.pool-sizing
      lesson=$1
      mkdir -p answers
      rm -f answers/pool-sizing.txt
      docker compose exec -T primary psql -U postgres -q \
        -c "DROP DATABASE IF EXISTS boxoffice WITH (FORCE)" -c "CREATE DATABASE boxoffice" >/dev/null
      docker compose exec -T primary psql -U postgres -d boxoffice -q -v ON_ERROR_STOP=1 \
        < "$lesson/files/schema.sql" >/dev/null 2>&1
      # The pgbouncer config is the container's own file: it survives a restart
      # of pgbouncer, so the entries are rewritten here every time. The check
      # runs the original pool through boxoffice_before, back to back with
      # yours, so both see the same machine.
      docker compose exec -T pgbouncer sh -c '
        f=/etc/pgbouncer/pgbouncer.ini
        sed -i "/^boxoffice\(_before\)\? *=/d" $f
        sed -i "s/^\[databases\]\$/[databases]\nboxoffice = host=primary port=5432 dbname=boxoffice auth_user=postgres pool_size=80\nboxoffice_before = host=primary port=5432 dbname=boxoffice auth_user=postgres pool_size=80/" $f'
      docker compose exec -T -e PGPASSWORD=devopslings primary \
        psql -h pgbouncer -U postgres pgbouncer -c RELOAD >/dev/null

      echo "scenario ready — the boxoffice database is behind pgbouncer with pool_size=80."
      echo
      echo "Run the on-sale (15 seconds, one JSON line):"
      echo "  bash $lesson/files/load.sh"
      echo "The pool is the boxoffice line in pgbouncer's /etc/pgbouncer/pgbouncer.ini. Apply an edit with:"
      echo "  docker compose exec -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres pgbouncer -c RELOAD"
      echo "Record your measurements in sandboxes/db-stack/answers/pool-sizing.txt."

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.pool-sizing
      lesson=$1
      ans=answers/pool-sizing.txt
      sizes=$(jq -rR 'fromjson? | select(.pool_size != null) | .pool_size' "$ans" 2>/dev/null | sort -n | uniq || true)
      if [ "$(printf '%s' "$sizes" | grep -c . || true)" -lt 4 ]; then
        echo "not yet: $ans needs the load.sh lines from at least four runs at four different pool"
        echo "sizes, one line each, as load.sh printed them. The size you choose comes from that"
        echo "table, so measure before you choose."
        exit 1
      fi
      if [ "$(head -1 <<<"$sizes")" -gt 8 ] || [ "$(tail -1 <<<"$sizes")" -lt 48 ]; then
        echo "not yet: your measurements cover pool sizes $(echo $sizes | tr ' ' ','). Cover both ends:"
        echo "at least one run at 8 or fewer, and one at 48 or more, so the table shows where it gets"
        echo "worse in both directions."
        exit 1
      fi

      cfg=$(docker compose exec -T pgbouncer sh -c 'grep -E "^boxoffice *=" /etc/pgbouncer/pgbouncer.ini' 2>/dev/null || true)
      file=$(grep -oE 'pool_size *= *[0-9]+' <<<"$cfg" | tr -dc '0-9' || true)
      running=$(docker compose exec -T -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres -d pgbouncer -Atc 'SHOW DATABASES' 2>/dev/null |
        awk -F'|' '$1 == "boxoffice" { print $6 }' || true)
      if [ -z "$cfg" ] || [ -z "$running" ]; then
        echo "not yet: pgbouncer has no boxoffice entry. Rerun the lesson's init to put it back."
        exit 1
      fi
      if [ -z "$file" ]; then
        echo "not yet: the boxoffice line in /etc/pgbouncer/pgbouncer.ini has no pool_size, so it"
        echo "takes default_pool_size. Set the pool on that line, where the next person will find it."
        exit 1
      fi
      if [ "$file" != "$running" ]; then
        echo "not yet: pgbouncer.ini says pool_size=$file for boxoffice, and the running pgbouncer uses"
        echo "$running. Reload it (RELOAD on the admin console) so the file is what runs."
        exit 1
      fi
      if ! grep -qx "$running" <<<"$sizes"; then
        echo "not yet: pool_size=$running is not one of the sizes you measured ($(echo $sizes | tr ' ' ','))."
        echo "Size the pool from the table: measure the size you pick."
        exit 1
      fi

      b=$(DB=boxoffice_before bash "$lesson/files/load.sh" 15 2>&1 | tail -1)
      r=$(bash "$lesson/files/load.sh" 15 2>&1 | tail -1)
      brate=$(jq -r '.bookings_per_s // empty' <<<"$b" 2>/dev/null || true)
      bp99=$(jq -r '.booking_p99_ms // empty' <<<"$b" 2>/dev/null || true)
      berrs=$(jq -r '.booking_errors // 0' <<<"$b" 2>/dev/null || echo 0)
      rate=$(jq -r '.bookings_per_s // empty' <<<"$r" 2>/dev/null || true)
      p99=$(jq -r '.booking_p99_ms // empty' <<<"$r" 2>/dev/null || true)
      errs=$(jq -r '.booking_errors // empty' <<<"$r" 2>/dev/null || true)
      if [ -z "$brate" ] || [ -z "$bp99" ]; then
        echo "not yet: the on-sale with the original pool (boxoffice_before) did not run: $b"
        echo "Rerun the lesson's init to put pgbouncer's entries back."
        exit 1
      fi
      if [ -z "$rate" ]; then
        echo "not yet: the on-sale did not run: $r"
        exit 1
      fi
      echo "this check ran the on-sale at pool_size=$running: $rate bookings/s, p99 ${p99}ms, $errs over the 500ms deadline"
      echo "(just before it, the original pool of 80: $brate bookings/s, p99 ${bp99}ms, $berrs over)"
      # One late booking in a hundred is noise from the machine; more is the pool.
      # A machine too slow for the deadline at any size is held to a quarter of
      # the original pool's late bookings, measured just before.
      if [ "$(( errs * 100 ))" -gt "$(( rate * 15 + errs ))" ] && [ "$(( errs * 4 ))" -gt "$berrs" ]; then
        echo "not yet: $errs bookings took longer than the app's 500ms deadline, and those customers saw an"
        echo "error. With $running server connections, that many backends share the CPU, and a booking"
        echo "holding a show's row lock is descheduled while every booking behind it waits."
        exit 1
      fi
      if [ "$rate" -lt "$(awk -v b="$brate" 'BEGIN { printf "%d", 0.85 * b }')" ]; then
        echo "not yet: $rate bookings a second is fewer than the original pool sold, with no booking late."
        echo "With $running server connections, CPU sits idle while bookings wait in pgbouncer for a"
        echo "connection to come free (cl_waiting in SHOW POOLS). Too small a pool is a queue of its own."
        exit 1
      fi
      if [ "$p99" -gt "$(( bp99 / 2 ))" ]; then
        echo "not yet: the booking p99 is ${p99}ms, not half the original's ${bp99}ms. Look at your table"
        echo "for the size where p99 is lowest and the rate has stopped rising."
        exit 1
      fi
      echo "PASS — pool_size=$running sells $rate seats a second (the original: $brate) with a p99 of ${p99}ms"
      echo "(the original: ${bp99}ms) and $errs bookings past the deadline."
---
