---
kind: lesson
title: "The backup nobody has restored"
description: |
  The shop's backup job has exited 0 every night for months. Restore what
  it wrote into an empty server and compare. Then make the job's exit
  status mean something, so the next time it fails somebody hears about it.
name: backup-then-restore
slug: backup-then-restore
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
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup') THEN DROP OWNED BY backup; END IF;
      END $$;
      DROP ROLE IF EXISTS backup;
      CREATE TABLE customers (id bigserial PRIMARY KEY, email text NOT NULL);
      INSERT INTO customers (email) SELECT 'customer' || g || '@example.test' FROM generate_series(1, 400) g;
      -- The backup role, set up when the shop had two tables.
      CREATE ROLE backup LOGIN PASSWORD 'backup';
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
      GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
      -- Added months later.
      CREATE TABLE refunds (id bigserial PRIMARY KEY, order_id bigint NOT NULL, cents int NOT NULL);
      INSERT INTO refunds (order_id, cents) SELECT g * 7, 500 + g FROM generate_series(1, 60) g;
      SQL
      mkdir -p /ha/backups
      cat > /ha/backups/backup.sh <<'SH'
      #!/bin/bash
      # Nightly logical backup of the shop database, as the read-only backup role.
      # Writes /ha/backups/shop.sql.gz, a plain SQL dump, gzipped.
      out=/ha/backups/shop.sql.gz
      PGUSER=backup PGPASSWORD=backup pg_dump --host=pg1 --dbname=shop | gzip > "$out"
      echo "backup written: $out ($(stat -c %s "$out") bytes)"
      SH
      chmod +x /ha/backups/backup.sh
      /ha/backups/backup.sh >/dev/null 2>&1 || true
      echo "scenario ready — last night's backup job:"
      echo
      echo "  \$ /ha/backups/backup.sh; echo \"exit \$?\""
      /ha/backups/backup.sh 2>/dev/null | sed 's/^/  /'
      echo "  exit 0"
      echo
      echo "  the job:           /ha/backups/backup.sh"
      echo "  an empty server:   scratchdb fresh   (then psql -h localhost -p 5433)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      work=$(mktemp -d)
      restore() {
        psql -qX -d postgres -c "ALTER DATABASE shop ALLOW_CONNECTIONS true" >/dev/null 2>&1 || true
        [ -f "$work/good.gz" ] && cp "$work/good.gz" /ha/backups/shop.sql.gz
        scratchdb stop >/dev/null 2>&1 || true
        rm -rf "$work"
      }
      trap restore EXIT
      if [ ! -x /ha/backups/backup.sh ]; then
        echo "not yet: /ha/backups/backup.sh is missing or not executable."
        exit 1
      fi

      # Round 1: the job, then a restore of what it wrote into an empty server.
      rc=0
      timeout 120 /ha/backups/backup.sh > "$work/run.log" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "not yet: /ha/backups/backup.sh exited $rc with the database up. Its last lines:"
        tail -4 "$work/run.log" | sed 's/^/         | /'
        exit 1
      fi
      f=/ha/backups/shop.sql.gz
      if [ ! -s "$f" ]; then
        echo "not yet: backup.sh exited 0 but there is no $f."
        exit 1
      fi
      cp "$f" "$work/good.gz"
      scratchdb fresh >/dev/null
      gunzip -c "$f" | psql -qX -h localhost -p 5433 -d postgres >"$work/restore.log" 2>&1 || true
      bad=""
      for t in customers orders refunds; do
        q="select count(*) || ' ' || coalesce(md5(string_agg(x::text, ',' order by id)), '-') from $t x"
        want=$(psql -tAX -c "$q")
        got=$(psql -tAX -h localhost -p 5433 -d postgres -c "$q" 2>/dev/null || echo "missing -")
        [ "$want" = "$got" ] && continue
        bad="$bad$(printf '\n         %-10s pg1: %-6s restored: %s' "$t" "${want%% *}" "${got%% *}")"
      done
      if [ -n "$bad" ]; then
        echo "not yet: backup.sh exited 0, and restoring $f ($(stat -c %s "$f") bytes) into an empty server"
        echo "         does not reproduce the shop. Rows per table:$bad"
        if [ "$(gunzip -c "$f" | grep -c '^-- PostgreSQL database dump complete' || true)" = 0 ]; then
          echo "         The dump has no 'dump complete' line: pg_dump stopped before the end. Run the pg_dump"
          echo "         line from backup.sh by hand, without the pipe, and read what it says."
        fi
        exit 1
      fi
      echo "round 1: backup.sh exited 0, and the restore matches pg1 row for row"

      # Round 2: the same job while the database refuses connections.
      psql -qX -d postgres -c "ALTER DATABASE shop ALLOW_CONNECTIONS false" >/dev/null
      rc=0
      timeout 120 /ha/backups/backup.sh > "$work/run.log" 2>&1 || rc=$?
      psql -qX -d postgres -c "ALTER DATABASE shop ALLOW_CONNECTIONS true" >/dev/null
      if [ "$rc" -eq 0 ]; then
        echo "not yet: with the shop database refusing every connection, backup.sh still exited 0:"
        tail -3 "$work/run.log" | sed 's/^/         | /'
        echo "         pg_dump failed, and nothing in the job turned that into a failure. A job that"
        echo "         reports success when it failed is what made this backup worthless for months."
        exit 1
      fi
      echo "round 2: with the database refusing connections, backup.sh exited $rc"
      echo
      echo "PASS — the backup restores exactly, and the job fails when pg_dump does."
---
