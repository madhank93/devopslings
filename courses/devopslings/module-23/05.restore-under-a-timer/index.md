---
kind: lesson
title: "Restore under a timer"
description: |
  The runbook promises a restore takes two seconds. That number was
  measured once, years ago, on a much smaller database. Run the drill with a
  stopwatch, find out where the time actually goes, and make the runbook
  tell the truth.
name: restore-under-a-timer
slug: restore-under-a-timer
createdAt: "2026-11-13"
timingSensitive: true

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 420
    run: |
      ha-reset
      psql -qX -v ON_ERROR_STOP=1 <<'SQL'
      SET client_min_messages = warning;
      DROP TABLE IF EXISTS events;
      CREATE TABLE events (
        id       bigserial PRIMARY KEY,
        order_id bigint NOT NULL,
        kind     text NOT NULL,
        detail   text NOT NULL,
        at       timestamptz NOT NULL
      );
      INSERT INTO events (order_id, kind, detail, at)
      SELECT (random() * 100000)::bigint,
             (ARRAY['placed', 'paid', 'packed', 'shipped', 'refunded'])[1 + g % 5],
             md5(g::text) || md5((g * 7)::text),
             now() - random() * interval '700 days'
      FROM generate_series(1, 2000000) g;
      CREATE INDEX ON events (order_id);
      CREATE INDEX ON events (at);
      CREATE INDEX ON events (kind, at);
      CREATE INDEX ON events (kind, order_id, at);
      CREATE INDEX ON events (detail);
      SQL
      mkdir -p /ha/backups /ha/dr
      pg_dump -Fc -f /ha/backups/shop.dump shop
      cat > /ha/dr/restore.sh <<'SH'
      #!/bin/bash
      # Restore drill: last night's dump into an empty server.
      set -euo pipefail
      scratchdb fresh
      pg_restore --no-owner --no-acl -h localhost -p 5433 -d postgres /ha/backups/shop.dump
      echo "restore complete"
      SH
      chmod +x /ha/dr/restore.sh
      cat > /ha/dr/runbook.txt <<'TXT'
      Shop database — restore runbook

        procedure:        /ha/dr/restore.sh
        restore_seconds:  2
        measured_rows:    40000    (rows in events when restore_seconds was measured)
        last_drill:       2024-03-11

      restore_seconds is what we quote to the business when they ask how long the
      database restore part of a recovery takes.
      TXT
      cat > /ha/answers/restore-drill.txt <<'TXT'
      # Seconds, as measured on this machine. Decimals are fine.
      # The whole procedure, /ha/dr/restore.sh:
      measured_total_seconds: ?
      # The same restore in two halves: tables and their rows, then indexes and constraints.
      data_seconds: ?
      indexes_seconds: ?
      TXT
      echo "scenario ready — the restore runbook:"
      echo
      sed 's/^/  /' /ha/dr/runbook.txt
      echo
      echo "  the drill:      /ha/dr/restore.sh"
      echo "  your timings:   /ha/answers/restore-drill.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      trap 'scratchdb stop >/dev/null 2>&1 || true' EXIT
      a=/ha/answers/restore-drill.txt
      r=/ha/dr/runbook.txt
      get() { sed -n "s/^[[:space:]]*$2[[:space:]]*:[[:space:]]*//p" "$1" 2>/dev/null | head -1 | awk '{print $1}' || true; }
      num() {  # num <file> <key> <var>
        local v; v=$(get "$1" "$2")
        if ! [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          echo "not yet: $2 in $1 is '${v:-missing}'; it needs a number of seconds."
          exit 1
        fi
        printf -v "$3" '%s' "$v"
      }
      num "$a" measured_total_seconds total
      num "$a" data_seconds data
      num "$a" indexes_seconds idx
      if [ ! -s /ha/backups/shop.dump ]; then
        echo "not yet: /ha/backups/shop.dump is gone. Reset the lesson to get it back."
        exit 1
      fi

      # The grader's own drill, in the same two halves.
      t() { python3 -c 'import time; print(time.monotonic())'; }
      scratchdb fresh >/dev/null
      s=$(t)
      pg_restore -O -x -h localhost -p 5433 -d postgres --section=pre-data --section=data /ha/backups/shop.dump
      m=$(t)
      pg_restore -O -x -h localhost -p 5433 -d postgres --section=post-data /ha/backups/shop.dump
      e=$(t)
      gd=$(awk -v a="$s" -v b="$m" 'BEGIN { printf "%.1f", b - a }')
      gi=$(awk -v a="$m" -v b="$e" 'BEGIN { printf "%.1f", b - a }')
      gt=$(awk -v a="$gd" -v b="$gi" 'BEGIN { printf "%.1f", a + b }')
      echo "grader's drill: ${gd}s data + ${gi}s indexes = ${gt}s"

      near() { awk -v x="$1" -v y="$2" 'BEGIN { exit !(x >= y / 2 && x <= y * 2) }'; }
      if ! near "$total" "$gt"; then
        echo "not yet: you measured the whole restore at ${total}s; the grader's took ${gt}s. Time /ha/dr/restore.sh"
        echo "         itself, start to finish — 'time /ha/dr/restore.sh' — and record the 'real' figure."
        exit 1
      fi
      if near "$data" "$gi" && near "$idx" "$gd" && ! near "$data" "$gd"; then
        echo "not yet: your data_seconds (${data}) and indexes_seconds (${idx}) look swapped: the grader's data half took"
        echo "         ${gd}s and its index half ${gi}s."
        exit 1
      fi
      if ! near "$data" "$gd" || ! near "$idx" "$gi"; then
        echo "not yet: you recorded ${data}s for the data and ${idx}s for the indexes; the grader's halves took ${gd}s and ${gi}s."
        echo "         pg_restore --section=pre-data --section=data restores the tables and rows;"
        echo "         --section=post-data then builds the indexes and constraints. Time each into a fresh server."
        exit 1
      fi

      promise=$(get "$r" restore_seconds)
      rows=$(get "$r" measured_rows | tr -d ",_")
      now_rows=$(psql -tAX -c "SELECT count(*) FROM events")
      if ! [[ $promise =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v p="$promise" -v g="$gt" 'BEGIN { exit !(p < g * 0.8) }'; then
        echo "not yet: the runbook promises restore_seconds: ${promise:-missing}. The restore takes about ${gt}s."
        echo "         The business plans around that number; make it one you measured."
        exit 1
      fi
      if awk -v p="$promise" 'BEGIN { exit !(p > 3600) }'; then
        echo "not yet: restore_seconds: $promise is over an hour, past the shop's whole RTO, for a ${gt}s restore."
        exit 1
      fi
      if [ "$rows" != "$now_rows" ]; then
        echo "not yet: the runbook's measured_rows is '${rows:-missing}', but events has $now_rows rows now."
        echo "         A restore time is only true for the size it was measured at; record that size with it,"
        echo "         so the next reader can see when the number has gone stale."
        exit 1
      fi
      echo "PASS — the restore takes ${gt}s, ${gi}s of it building indexes, and the runbook now says so."
---
