---
kind: lesson
title: "Kill the toil"
description: |
  Every Monday someone spends forty minutes pasting the same SQL into psql
  and the same numbers into the ops channel. Turn it into a job that runs by
  itself, reports what it did, and does the right thing when web1 and web2
  both run it at once.
name: kill-the-toil
slug: kill-the-toil
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/sre
      cat > /var/lib/devopslings/toil-seed.sql <<'SQL'
      -- A week of the shop's leftovers: :stale carts and :old orders to clean up,
      -- next to fresh ones that must stay.
      BEGIN;
      TRUNCATE toil.carts, toil.orders, toil.orders_archive;
      INSERT INTO toil.carts
        SELECT 'fresh-' || g, now() - (random() * 166 + 1) * interval '1 hour' FROM generate_series(1, 40) g;
      INSERT INTO toil.carts VALUES ('edge-keep', now() - interval '6 days 23 hours');
      INSERT INTO toil.carts
        SELECT 'stale-' || g, now() - (random() * 50 + 7.05) * interval '1 day' FROM generate_series(1, :stale) g;
      INSERT INTO toil.orders (placed_at, total)
        SELECT now() - random() * interval '89 days', round((random() * 200)::numeric, 2) FROM generate_series(1, 120);
      INSERT INTO toil.orders (placed_at, total) VALUES (now() - interval '89 days 23 hours', 9.99);
      INSERT INTO toil.orders (placed_at, total)
        SELECT now() - (random() * 300 + 90.05) * interval '1 day', round((random() * 200)::numeric, 2)
        FROM generate_series(1, :old);
      COMMIT;
      SQL
      psql -qX <<'SQL'
      DROP SCHEMA IF EXISTS toil CASCADE;
      CREATE SCHEMA toil;
      CREATE TABLE toil.carts (sid text PRIMARY KEY, touched_at timestamptz NOT NULL);
      CREATE TABLE toil.orders (id bigserial PRIMARY KEY, placed_at timestamptz NOT NULL, total numeric NOT NULL);
      CREATE TABLE toil.orders_archive (id bigint NOT NULL, placed_at timestamptz NOT NULL, total numeric NOT NULL);
      SQL
      psql -qX -v stale=37 -v old=58 -f /var/lib/devopslings/toil-seed.sql
      rm -f /ha/sre/weekly-cleanup /ha/sre/toil.log
      cat > /ha/sre/runbook-weekly.md <<'MD'
      # Monday clean-up (on-call, every week, ~40 minutes)

      From ops, in psql.

      1. Carts nobody has touched for 7 days. Note the count, then delete them.

             SELECT count(*) FROM toil.carts WHERE touched_at < now() - interval '7 days';
             DELETE FROM toil.carts WHERE touched_at < now() - interval '7 days';

      2. Orders older than 90 days move to the archive. Note the count.

             INSERT INTO toil.orders_archive
               SELECT * FROM toil.orders WHERE placed_at < now() - interval '90 days';
             DELETE FROM toil.orders WHERE placed_at < now() - interval '90 days';

      3. Post both counts, and how long it took, in #ops.
      MD
      echo "scenario ready — it is Monday, and this week's leftovers are waiting."
      echo
      echo "  the runbook:           /ha/sre/runbook-weekly.md"
      echo "  the job you write:     /ha/sre/weekly-cleanup   (runs on web1 and web2)"
      echo "  what schedules it:     /ha/app/scheduler.sh     (runs on web1 and web2)"
      echo "  where it reports:      /ha/sre/toil.log"
      echo
      echo "  web1 and web2 have python3 with psycopg and etcdctl; they do not have psql."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      seed=/var/lib/devopslings/toil-seed.sql
      job=/ha/sre/weekly-cleanup
      log=/ha/sre/toil.log
      if [ ! -f "$seed" ]; then
        echo "not yet: the scenario's seed is missing. Reset the lesson."
        exit 1
      fi
      if [ ! -x "$job" ]; then
        echo "not yet: $job is missing or not executable."
        exit 1
      fi
      q() { psql -qtAX -c "$1" 2>/dev/null || echo "?"; }
      week() {  # week: seed a fresh week, set STALE/OLD and the log marker MARK
        STALE=$((20 + RANDOM % 30)); OLD=$((30 + RANDOM % 40))
        # Empty the last week first, and let a run already in flight log it,
        # so every line after MARK reports this week's rows only.
        psql -qX -v stale=0 -v old=0 -f "$seed" >/dev/null
        sleep 2
        MARK=0; [ ! -f "$log" ] || MARK=$(wc -l < "$log")
        psql -qX -v stale="$STALE" -v old="$OLD" -f "$seed" >/dev/null
      }
      clean() {  # clean: true once this week's leftovers are gone
        [ "$(q "SELECT (SELECT count(*) FROM toil.carts WHERE sid LIKE 'stale-%') + (SELECT count(*) FROM toil.orders WHERE placed_at < now() - interval '90 days')")" = 0 ]
      }
      logged() {  # logged <field>: the sum of field=N over lines since MARK
        [ -f "$log" ] || { echo 0; return; }
        tail -n +"$((MARK + 1))" "$log" | { grep -Eo "(^|[[:space:]])$1=[0-9]+" || true; } | cut -d= -f2 | awk '{ s += $1 } END { print s + 0 }'
      }
      judge() {  # judge <round>: data and report both right for this week
        local carts fresh orders arch distinct
        carts=$(q "SELECT count(*) FROM toil.carts WHERE sid LIKE 'stale-%'")
        fresh=$(q "SELECT count(*) FROM toil.carts WHERE sid NOT LIKE 'stale-%'")
        orders=$(q "SELECT count(*) FROM toil.orders")
        arch=$(q "SELECT count(*) FROM toil.orders_archive")
        distinct=$(q "SELECT count(DISTINCT id) FROM toil.orders_archive")
        if [ "$fresh" != 41 ]; then
          echo "not yet: $1: $((41 - ${fresh/\?/41})) carts touched within the last 7 days were deleted. Only"
          echo "         carts untouched for 7 days go; one touched 6 days 23 hours ago stays."
          exit 1
        fi
        if [ "$carts" != 0 ] || [ "$orders" != 121 ]; then
          echo "not yet: $1: $carts carts older than 7 days are still there, and toil.orders has $orders rows"
          echo "         (121 are under 90 days old and should stay; $OLD were older)."
          exit 1
        fi
        if [ "$distinct" != "$OLD" ]; then
          echo "not yet: $1: the archive holds $distinct of the $OLD orders that were moved out of toil.orders."
          echo "         An order that leaves toil.orders and never reaches the archive is lost."
          exit 1
        fi
        if [ "$arch" != "$OLD" ]; then
          echo "not yet: $1: $OLD orders were archived, and toil.orders_archive now has $arch rows: $((arch - OLD))"
          echo "         of them are duplicates. Both copies of the job copied the same old orders before"
          echo "         either deleted them. Copy-then-delete in two steps is safe for one person at a"
          echo "         keyboard; it is not safe for two machines running it at the same moment."
          exit 1
        fi
        if [ "$(logged carts_deleted)" != "$STALE" ] || [ "$(logged orders_archived)" != "$OLD" ]; then
          echo "not yet: $1: the job deleted $STALE carts and archived $OLD orders, and $log says"
          echo "         carts_deleted=$(logged carts_deleted) orders_archived=$(logged orders_archived) across its new lines:"
          tail -n +"$((MARK + 1))" "$log" 2>/dev/null | tail -4 | sed 's/^/         | /' || true
          [ -f "$log" ] || echo "         $log does not exist: nothing has reported anything."
          echo "         Each run appends one line with carts_deleted=N orders_archived=N seconds=N,"
          echo "         where N is what that run itself changed. That line is how anyone knows it ran."
          exit 1
        fi
        if ! tail -n +"$((MARK + 1))" "$log" | grep -Eq '(^|[[:space:]])seconds=[0-9]+(\.[0-9]+)?([[:space:]]|$)'; then
          echo "not yet: $1: the job's lines in $log have no seconds=N. How long it takes is the other half"
          echo "         of the measurement: that is the time it saves someone every week."
          exit 1
        fi
      }

      # 1. One run, by hand, on web1.
      week
      out=$(docker exec devopslings-ha-web1 "$job" 2>&1) || {
        echo "not yet: $job exited non-zero on web1. Its output:"
        printf '%s\n' "$out" | tail -5 | sed 's/^/         | /'
        exit 1
      }
      for _ in $(seq 10); do clean && break; sleep 1; done
      judge "one run on web1"
      echo "one run on web1: $STALE carts deleted, $OLD orders archived, and reported"

      # 2. web1 and web2 at the same moment, as a scheduler on both will do.
      week
      docker exec devopslings-ha-web1 "$job" > /root/toil-web1.out 2>&1 & p1=$!
      docker exec devopslings-ha-web2 "$job" > /root/toil-web2.out 2>&1 & p2=$!
      r1=0; r2=0; wait "$p1" || r1=$?; wait "$p2" || r2=$?
      if [ "$r1" != 0 ] || [ "$r2" != 0 ]; then
        echo "not yet: run on web1 and web2 at the same moment, the job exited $r1 on web1 and $r2 on web2:"
        tail -n 3 /root/toil-web1.out /root/toil-web2.out 2>/dev/null | sed 's/^/         | /' || true
        echo "         A job that fails whenever two copies overlap pages someone every week."
        exit 1
      fi
      judge "web1 and web2 together"
      echo "web1 and web2 at once: nothing archived twice, and the reports add up"

      # 3. Nobody runs it: the scheduler does.
      week
      for _ in $(seq 45); do clean && break; sleep 1; done
      if ! clean; then
        echo "not yet: a fresh week of leftovers was seeded 45 seconds ago and nothing has cleaned it."
        if [ ! -f /ha/app/scheduler.sh ]; then
          echo "         /ha/app/scheduler.sh does not exist, so nothing runs the job unless a person does."
        else
          echo "         /ha/app/scheduler.sh exists; its output is in /ha/web1/scheduler.log. In the sandbox a"
          echo "         week is 15 seconds: the job has to run at least that often."
        fi
        exit 1
      fi
      sleep 2
      judge "the scheduled run"
      secs=$(tail -n +"$((MARK + 1))" "$log" | grep -Eo 'seconds=[0-9.]+' | cut -d= -f2 | sort -n | tail -1)
      echo "unattended: cleaned within the week, and reported (${secs}s, against ~40 minutes by hand)"
      echo
      echo "PASS — the Monday clean-up runs itself, says what it did, and is safe when it runs twice."
---
