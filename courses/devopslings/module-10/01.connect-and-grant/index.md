---
kind: lesson
title: "the application login can drop every table it reads"
description: |
  The service connects as a role that owns the schema, so a bug, an injection
  or a bad migration can destroy it. Give the application the rights it uses
  and nothing more — and prove the difference by watching a DROP get refused.
name: connect-and-grant
slug: connect-and-grant
createdAt: "2026-09-04"

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      # Start from a known state whatever an earlier attempt left behind.
      #
      # REASSIGN before DROP OWNED, and never DROP OWNED ... CASCADE: by the
      # time this runs a second time `app` owns the seeded tables, and dropping
      # what it owns would take ten million rows with it. The seed is only
      # rebuilt when the volume is, so that would be unrecoverable inside a
      # lesson. REASSIGN moves the tables back to postgres first, leaving
      # DROP OWNED with nothing but grants to remove.
      psql -q <<'SQL'
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
          EXECUTE 'REASSIGN OWNED BY app TO postgres';
          EXECUTE 'DROP OWNED BY app';
          EXECUTE 'DROP ROLE app';
        END IF;
      END $$;
      SQL

      # How it is today: one role for everything, and it owns the tables. The
      # application's connection string is this role, so anything the
      # application can be tricked into running, it is entitled to run.
      psql -q <<'SQL'
      CREATE ROLE app LOGIN PASSWORD 'app-secret';
      ALTER TABLE orders    OWNER TO app;
      ALTER TABLE customers OWNER TO app;
      ALTER SEQUENCE orders_id_seq    OWNER TO app;
      ALTER SEQUENCE customers_id_seq OWNER TO app;
      GRANT ALL ON SCHEMA public TO app;
      SQL

      echo "scenario ready"
      echo
      echo "  primary:  localhost:15432   db 'shop', superuser postgres / devopslings"
      echo "  the app connects as:  app / app-secret"
      echo
      echo "What the application does, all day:"
      echo "    SELECT ... FROM orders WHERE customer_id = ..."
      echo "    INSERT INTO orders ..."
      echo "    UPDATE orders SET status = ..."
      echo
      echo "What it can also do, today:"
      echo "    PGPASSWORD=app-secret psql -h 127.0.0.1 -U app -d shop -c 'DROP TABLE orders'"
      echo
      echo "Do not run that. Work out why it would succeed, and make it stop."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      su_psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      app_psql() { PGPASSWORD=app-secret command psql -qtAX -U app -d shop -h 127.0.0.1 "$@"; }

      if ! su_psql -c 'SELECT 1' >/dev/null 2>&1; then
        echo "not yet: cannot reach the primary as postgres"
        exit 1
      fi

      if ! app_psql -c 'SELECT 1' >/dev/null 2>&1; then
        echo "not yet: the application cannot connect as 'app' at all any more."
        echo "Least privilege is not no privilege — the service still has to work."
        exit 1
      fi

      # 1. The workload the application actually runs has to keep working.
      if ! app_psql -c 'SELECT count(*) FROM orders WHERE customer_id = 42' >/dev/null 2>&1; then
        echo "not yet: 'app' can no longer SELECT from orders, which is most of what"
        echo "the service does."
        exit 1
      fi
      if ! app_psql -c "INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
                        VALUES (42, 'placed', 'grader-probe', 1234, now())" >/dev/null 2>&1; then
        echo "not yet: 'app' can no longer INSERT into orders. Read-only is a different"
        echo "role than the one the application needs."
        exit 1
      fi
      if ! app_psql -c "UPDATE orders SET status = 'picked' WHERE reference = 'grader-probe'" >/dev/null 2>&1; then
        echo "not yet: 'app' can no longer UPDATE orders."
        exit 1
      fi
      if ! app_psql -c "DELETE FROM orders WHERE reference = 'grader-probe'" >/dev/null 2>&1; then
        echo "not yet: 'app' can no longer DELETE from orders."
        exit 1
      fi

      # 2. And the thing it must not be able to do.
      #
      # Inside a transaction that is rolled back, because Postgres checks the
      # permission when the statement executes and its DDL is transactional —
      # so this asks the real question without ever being able to answer it by
      # destroying ten million rows. A grader that has to break the sandbox to
      # find out whether the sandbox is breakable is not a grader.
      drop_err=$(app_psql <<'SQL' 2>&1 || true
      BEGIN;
      DROP TABLE orders;
      ROLLBACK;
      SQL
      )
      if ! su_psql -c "SELECT to_regclass('public.orders') IS NOT NULL" | grep -q '^t$'; then
        echo "not yet: orders is gone. The grader only ever attempts the DROP inside a"
        echo "transaction it rolls back, so something else dropped it — most likely the"
        echo "example in the lesson text, run for real. Rebuild with:"
        echo "    devopslings reset connect-and-grant"
        exit 1
      fi
      # Ownership is the mechanism people miss: a role that owns a table can
      # always drop it, whatever has been revoked. So when the DROP is allowed,
      # the message says which of the two reasons it was — a bare "that did not
      # fail" would send a student back to write more REVOKEs, which is exactly
      # the thing that cannot work.
      owner=$(su_psql -c "SELECT tableowner FROM pg_tables WHERE tablename = 'orders'")

      case "$drop_err" in
        *"must be owner"*|*"permission denied"*|*"insufficient"*) ;;
        *)
          echo "not yet: 'app' was allowed to DROP TABLE orders."
          if [ "$owner" = "app" ]; then
            echo
            echo "'app' still owns the table. DROP is not a privilege — there is no"
            echo "GRANT DROP in Postgres and no REVOKE that removes it. The right to drop"
            echo "a table follows ownership, so no amount of revoking will take it away"
            echo "while the table still belongs to 'app'. Give it to another role."
          else
            echo
            echo "The table is owned by '${owner}', so this is not ownership. Something"
            echo "else still grants it — check whether 'app' has been made a member of a"
            echo "role that owns the table, or holds a superuser attribute."
            echo "  ${drop_err:-the statement returned no error}"
          fi
          exit 1
          ;;
      esac

      # 3. And it must not be able to help itself to more.
      if app_psql -c 'CREATE TABLE grader_probe_tbl (id int)' >/dev/null 2>&1; then
        su_psql -c 'DROP TABLE IF EXISTS grader_probe_tbl' >/dev/null 2>&1 || true
        echo "not yet: 'app' can still create tables in the public schema. A role that"
        echo "can create objects can shadow the ones it is not allowed to touch."
        exit 1
      fi

      echo "PASS — the application can read and write orders, does not own it, cannot"
      echo "drop it, and cannot create tables of its own."
      echo "DROP was refused with: $(printf '%s' "$drop_err" | head -1)"
---
