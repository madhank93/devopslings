---
kind: lesson
title: "Take a backup, then open it"
description: |
  The nightly backup job runs on the database host and leaves a dump in
  /ha/backups. Run it, then open the file and find out what it actually
  holds. One of the shop's three tables is not in it the way you would
  expect.
name: take-a-backup
slug: take-a-backup
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
      psql -qX -v ON_ERROR_STOP=1 <<'SQL'
      SET client_min_messages = warning;
      DROP TABLE IF EXISTS customers, refunds;
      CREATE TABLE customers (id bigserial PRIMARY KEY, email text NOT NULL);
      INSERT INTO customers (email) SELECT 'customer' || g || '@example.test' FROM generate_series(1, 400) g;
      CREATE TABLE refunds (id bigserial PRIMARY KEY, order_id bigint NOT NULL, cents int NOT NULL);
      INSERT INTO refunds (order_id, cents) SELECT g * 7, 500 + g FROM generate_series(1, 60) g;
      SQL
      # Which table's rows the job leaves out is drawn per scenario, so the
      # answer has to come from the file.
      skip=$(printf 'customers\norders\nrefunds\n' | shuf -n1)
      docker exec -i -u postgres devopslings-ha-pg1 sh -c 'cat > /var/lib/postgresql/nightly-backup.sh' <<SH
      #!/bin/bash
      # Nightly backup of the shop database, run on pg1 as postgres.
      set -euo pipefail
      pg_dump --dbname=shop --exclude-table-data=$skip --file=/ha/backups/shop.sql
      SH
      mkdir -p /ha/backups
      chown postgres:postgres /ha/backups
      cat > /ha/backups/nightly.sh <<'SH'
      #!/bin/bash
      # Runs the nightly backup job on the database host. Output: /ha/backups/shop.sql
      set -euo pipefail
      docker exec -u postgres devopslings-ha-pg1 bash /var/lib/postgresql/nightly-backup.sh
      echo "nightly backup finished: $(ls -l /ha/backups/shop.sql)"
      SH
      chmod +x /ha/backups/nightly.sh
      cat > /ha/answers/take-a-backup.txt <<'TXT'
      # For each table: yes if /ha/backups/shop.sql would restore its rows,
      # no if it would not.
      customers: ?
      orders: ?
      refunds: ?
      TXT
      echo "scenario ready — the shop has three tables:"
      echo
      psql -X -c "select 'customers' as table, count(*) as rows from customers union all select 'orders', count(*) from orders union all select 'refunds', count(*) from refunds"
      echo "  the backup job:   /ha/backups/nightly.sh"
      echo "  your answers:     /ha/answers/take-a-backup.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      f=/ha/backups/shop.sql
      if [ ! -s "$f" ]; then
        echo "not yet: there is no $f. Run /ha/backups/nightly.sh to take the backup."
        exit 1
      fi
      if ! grep -q '^-- PostgreSQL database dump complete' "$f"; then
        echo "not yet: $f does not end with pg_dump's 'dump complete' line — it is not a whole dump."
        echo "         Run /ha/backups/nightly.sh again rather than editing the file."
        exit 1
      fi
      skip=$(docker exec devopslings-ha-pg1 sed -n 's/.*--exclude-table-data=\([a-z]*\).*/\1/p' /var/lib/postgresql/nightly-backup.sh 2>/dev/null || true)
      if [ -z "$skip" ]; then
        echo "not yet: the backup job on pg1 has been changed or removed. Reset the lesson to put it back."
        exit 1
      fi
      # The answers are graded against the job's dump, so a hand-run full dump has to be replaced first.
      if grep -q "^COPY public\.$skip " "$f"; then
        echo "not yet: $f holds rows for every table, so it was not written by the nightly job."
        echo "         The question is about the job's backup: run /ha/backups/nightly.sh and open what it writes."
        exit 1
      fi
      a=/ha/answers/take-a-backup.txt
      ans() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 | tr -d ' \t' | tr '[:upper:]' '[:lower:]' || true; }
      for t in customers orders refunds; do
        v=$(ans "$t")
        case $v in yes|no) ;; *)
          echo "not yet: '$t' in $a is '${v:-missing}'; answer yes or no."
          exit 1 ;;
        esac
        rows=$(awk -v t="$t" '$0 ~ "^COPY public\\." t " " {c=1; next} c && /^\\\.$/ {exit} c {n++} END {print n+0}' "$f")
        if [ "$t" = "$skip" ] && [ "$v" = yes ]; then
          echo "not yet: you said the dump would restore the rows of $t. It would not."
          echo "         Search the file for $t: its CREATE TABLE is there, so the table would come back —"
          echo "         but there is no COPY block with its rows. It would come back empty."
          exit 1
        fi
        if [ "$t" != "$skip" ] && [ "$v" = no ]; then
          echo "not yet: you said the dump would not restore the rows of $t. Look for the line"
          echo "         'COPY public.$t' in $f: the $rows lines after it, up to '\\.', are its rows."
          exit 1
        fi
      done
      echo "PASS — the dump holds the schema of all three tables, and the rows of all but $skip."
---
