---
kind: lesson
title: "Recover to the moment before the DELETE"
description: |
  A cleanup job deleted almost every order, and the shop kept trading
  afterwards. There is a base backup from before it and a WAL archive
  through it. Bring the deleted orders back — exactly as they were — without
  losing a single order placed since.
name: pitr
slug: pitr
createdAt: "2026-11-13"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /ha/archive/wal /ha/dr
      chown -R postgres:postgres /ha/archive
      psql -qX -v ON_ERROR_STOP=1 \
        -c "ALTER SYSTEM SET archive_mode = on" \
        -c "ALTER SYSTEM SET archive_command = 'test ! -f /ha/archive/wal/%f && cp %p /ha/archive/wal/%f'"
      docker restart devopslings-ha-pg1 >/dev/null
      for _ in $(seq 120); do pg_isready -q -h pg1 && break; sleep 0.5; done
      [ "$(psql -tAX -c 'show archive_mode')" = on ]

      # A known starting set: SEED-n has id n.
      psql -qX -v ON_ERROR_STOP=1 -c "TRUNCATE orders RESTART IDENTITY" \
        -c "INSERT INTO orders (reference) SELECT 'SEED-' || g FROM generate_series(1, 1000) g"
      # 06:00 — the nightly base backup.
      PGPASSWORD=replicate pg_basebackup -h pg1 -U replicator -D /ha/archive/base -Ft -z -X none -c fast 2>/dev/null
      # The morning's trade, then the cleanup with the wrong cutoff, then more trade.
      psql -qX -v ON_ERROR_STOP=1 -c "INSERT INTO orders (reference) SELECT 'MORNING-' || g FROM generate_series(1, 250) g"
      sleep 2
      psql -qX -v ON_ERROR_STOP=1 -c "DELETE FROM orders WHERE placed_at < now()"
      sleep 2
      for i in $(seq 1 40); do
        psql -qX -v ON_ERROR_STOP=1 -c "INSERT INTO orders (reference) VALUES ('AFTER-$i')"
      done
      seg=$(psql -tAX -c "SELECT pg_walfile_name(pg_switch_wal())")
      for _ in $(seq 60); do
        [ "$(psql -tAX -c "SELECT coalesce(last_archived_wal >= '$seg', false) FROM pg_stat_archiver")" = t ] && break
        sleep 0.5
      done

      cat > /ha/dr/INCIDENT.txt <<'TXT'
      Support: almost every order has vanished from the admin screen. New orders are
      coming in normally.

      Engineering: a cleanup job that should remove orders older than two years ran
      this morning with the wrong cutoff. It ran once, a little after the morning's
      orders came in.

      Ask: get the deleted orders back, as they were, ids included. Do not lose the
      orders customers have placed since — the shop must stay open while you work.
      TXT
      echo "scenario ready — orders on pg1 right now:"
      psql -X -c "SELECT split_part(reference, '-', 1) AS kind, count(*) FROM orders GROUP BY 1 ORDER BY 1"
      echo "  what happened:           /ha/dr/INCIDENT.txt"
      echo "  last night's base backup: /ha/archive/base/"
      echo "  the WAL archive:          /ha/archive/wal/"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      # The deleted set is fixed by the scenario: the 1000 seed orders and the
      # 250 morning orders. Afterwards the shop took AFTER-1..40.
      pre=$(psql -tAX -c "SELECT count(*) FROM orders WHERE reference ~ '^(SEED|MORNING)-'")
      seed=$(psql -tAX -c "SELECT count(DISTINCT reference) FROM orders WHERE reference ~ '^SEED-'")
      morning=$(psql -tAX -c "SELECT count(DISTINCT reference) FROM orders WHERE reference ~ '^MORNING-'")
      after=$(psql -tAX -c "SELECT count(DISTINCT reference) FROM orders WHERE reference ~ '^AFTER-'")
      dups=$(psql -tAX -c "SELECT count(*) FROM (SELECT reference FROM orders GROUP BY 1 HAVING count(*) > 1) d")
      if [ "$after" -lt 40 ]; then
        echo "not yet: only $after of the 40 orders placed after the DELETE are on pg1."
        echo "         Customers placed those orders and were told they succeeded. Replacing the whole database"
        echo "         with a restored copy rewinds them too: restore to the side, and bring back only what"
        echo "         the DELETE removed."
        exit 1
      fi
      if [ "$dups" -gt 0 ]; then
        echo "not yet: $dups references appear on more than one row of orders. Something was inserted twice."
        exit 1
      fi
      if [ "$seed" -eq 0 ] && [ "$morning" -eq 0 ]; then
        echo "not yet: none of the deleted orders are back on pg1 yet ($after orders placed since are there)."
        exit 1
      fi
      if [ "$seed" -lt 1000 ]; then
        echo "not yet: $((1000 - seed)) of the 1000 orders from before last night's backup are still missing."
        exit 1
      fi
      if [ "$morning" -lt 250 ]; then
        echo "not yet: the older orders are back, but $((250 - morning)) of the 250 placed this morning are not."
        echo "         They were placed after the base backup and before the DELETE, so they exist only in the"
        echo "         WAL archive. A restore that stops at the end of the base backup, or at a target before"
        echo "         them, does not have them."
        exit 1
      fi
      bad=$(psql -tAX -c "SELECT count(*) FROM orders WHERE reference ~ '^(SEED|MORNING)-'
                          AND id <> CASE WHEN reference ~ '^SEED-' THEN split_part(reference, '-', 2)::bigint
                                         ELSE 1000 + split_part(reference, '-', 2)::bigint END")
      if [ "$bad" -gt 0 ]; then
        echo "not yet: all 1250 deleted orders are back, but $bad of them have a different id than before."
        echo "         Other systems refer to orders by id. Copy the rows back whole, id included."
        exit 1
      fi
      echo "PASS — the $pre deleted orders are back as they were, and the $after placed since are untouched."
---
