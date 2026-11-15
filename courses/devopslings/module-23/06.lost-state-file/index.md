---
kind: lesson
title: "The state file is gone"
description: |
  The reporting database on pg1 is managed by OpenTofu, and the state file
  that tied the code to the real objects has been deleted. The objects are
  all still there, full of data. Get OpenTofu managing them again without
  creating, dropping or replacing a single one.
name: lost-state-file
slug: lost-state-file
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
      psql -qX -d postgres -v ON_ERROR_STOP=1 <<'SQL'
      SET client_min_messages = warning;
      DROP DATABASE IF EXISTS analytics;
      DROP ROLE IF EXISTS analyst;
      DROP ROLE IF EXISTS reporting;
      SQL
      mkdir -p /ha/infra
      cat > /ha/infra/main.tf <<'TF'
      # The reporting database on pg1: who owns it and who can log in to read it.
      terraform {
        required_providers {
          postgresql = {
            source  = "cyrilgdn/postgresql"
            version = "1.27.0"
          }
        }
      }

      provider "postgresql" {
        host     = "pg1"
        username = "postgres"
        password = "devopslings"
        sslmode  = "disable"
      }

      resource "postgresql_role" "reporting" {
        name = "reporting"
      }

      resource "postgresql_role" "analyst" {
        name             = "analyst"
        login            = true
        connection_limit = 5
        roles            = [postgresql_role.reporting.name]
      }

      resource "postgresql_database" "analytics" {
        name  = "analytics"
        owner = postgresql_role.reporting.name
      }

      resource "postgresql_schema" "marts" {
        name     = "marts"
        database = postgresql_database.analytics.name
        owner    = postgresql_role.reporting.name
      }
      TF
      cd /ha/infra
      tofu init -input=false -no-color >/dev/null
      tofu apply -auto-approve -input=false -no-color >/dev/null
      # A year of reports, built by a job outside OpenTofu.
      psql -qX -d analytics -v ON_ERROR_STOP=1 <<'SQL'
      CREATE TABLE marts.daily_sales (day date PRIMARY KEY, orders int NOT NULL, cents bigint NOT NULL);
      INSERT INTO marts.daily_sales SELECT d::date, 50 + (random() * 100)::int, (random() * 1e6)::bigint
      FROM generate_series(current_date - 364, current_date, interval '1 day') d;
      ALTER TABLE marts.daily_sales OWNER TO reporting;
      SQL
      # What existed before the loss, kept off /ha where the student works.
      psql -tAX -d postgres -c "SELECT string_agg(rolname || '=' || oid, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('reporting', 'analyst')
                                UNION ALL SELECT 'analytics=' || oid FROM pg_database WHERE datname = 'analytics'" \
        | docker exec -i devopslings-ha-pg1 sh -c 'cat > /var/lib/postgresql/infra-oids'
      # The loss.
      rm -f /ha/infra/terraform.tfstate /ha/infra/terraform.tfstate.backup
      echo "scenario ready — on pg1, as OpenTofu built it:"
      echo
      psql -X -d analytics -c "\du+ reporting|analyst" -c "\dn marts" -c "SELECT count(*) AS days_of_reports FROM marts.daily_sales"
      echo "  the code:          /ha/infra/main.tf"
      echo "  the state file:    /ha/infra/terraform.tfstate   (gone)"
      echo "  cd /ha/infra && tofu plan"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      before=()
      read -r -a before <<<"$(docker exec devopslings-ha-pg1 cat /var/lib/postgresql/infra-oids 2>/dev/null | tr '\n' ' ')"
      for name in analytics reporting analyst; do
        old=""
        for kv in "${before[@]}"; do [ "${kv%%=*}" = "$name" ] && old=${kv#*=}; done
        if [ -z "$old" ]; then
          echo "not yet: the scenario's record of the original objects is missing. Reset the lesson."
          exit 1
        fi
        case $name in
          analytics) now=$(psql -tAX -d postgres -c "SELECT oid FROM pg_database WHERE datname = 'analytics'") ;;
          *) now=$(psql -tAX -d postgres -c "SELECT oid FROM pg_roles WHERE rolname = '$name'") ;;
        esac
        if [ -z "$now" ]; then
          echo "not yet: $name no longer exists on pg1. It was there, in use, when the state file was lost."
          exit 1
        fi
        if [ "$now" != "$old" ]; then
          echo "not yet: $name was dropped and created again (oid $old is now $now)."
          if [ "$name" = analytics ]; then
            days=$(psql -tAX -d analytics -c "SELECT count(*) FROM marts.daily_sales" 2>/dev/null || echo 0)
            echo "         marts.daily_sales had 365 days of reports; it has ${days:-0} now. Recreating a database"
            echo "         recreates it empty — OpenTofu never knew about the data inside it."
          else
            echo "         Anything granted to the old role, or owned by it, went with it."
          fi
          exit 1
        fi
      done
      days=$(psql -tAX -d analytics -c "SELECT count(*) FROM marts.daily_sales" 2>/dev/null || echo 0)
      if [ "$days" != 365 ]; then
        echo "not yet: marts.daily_sales has ${days:-no} rows; it had 365."
        exit 1
      fi

      cd /ha/infra
      want="postgresql_database.analytics postgresql_role.analyst postgresql_role.reporting postgresql_schema.marts"
      if ! tofu init -input=false -no-color >/dev/null 2>&1; then
        echo "not yet: tofu init fails in /ha/infra:"
        tofu init -input=false -no-color 2>&1 | grep -iE 'error' | head -3 | sed 's/^/         | /' || true
        exit 1
      fi
      for addr in $want; do
        rtype=${addr%%.*}
        rname=${addr#*.}
        if ! grep -Eq "^[[:space:]]*resource[[:space:]]+\"$rtype\"[[:space:]]+\"$rname\"" main.tf; then
          echo "not yet: main.tf no longer declares $addr. Removing the code makes the plan empty because"
          echo "         nothing is managed any more; the object is still on pg1, and now nobody owns it."
          exit 1
        fi
      done
      have=$(tofu state list 2>/dev/null | sort | tr '\n' ' ' || true)
      missing=""
      for addr in $want; do
        case " $have " in *" $addr "*) ;; *) missing="$missing $addr" ;; esac
      done
      rc=0
      tofu plan -detailed-exitcode -lock=false -input=false -no-color > /tmp/plan.out 2>&1 || rc=$?
      if [ -n "$missing" ] || [ "$rc" -ne 0 ]; then
        echo "not yet: OpenTofu does not yet manage everything in main.tf."
        [ -n "$missing" ] && echo "         Not in the state:$missing"
        grep -E '^(Plan:|Error:)|will be (created|updated|destroyed|replaced)|must be replaced' /tmp/plan.out | head -6 | sed 's/^/         | /' || true
        if [ -n "$missing" ]; then
          echo "         Every one of them exists on pg1 already: creating it fails, and dropping it loses what is in it."
        else
          echo "         Everything is in the state, but the plan still has changes: apply them, then plan again."
        fi
        exit 1
      fi
      echo "PASS — all four objects are back under OpenTofu, untouched, and the plan is empty."
---
