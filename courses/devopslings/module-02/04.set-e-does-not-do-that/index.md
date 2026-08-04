---
kind: lesson
title: "set -e is at the top and the failure went through anyway"
description: |
  provision-tenant starts with `set -euo pipefail` and still completed a tenant
  whose database was never created. There are four contexts where `set -e` is
  suspended by design, and this script manages to hit all of them.
name: set-e-does-not-do-that
slug: set-e-does-not-do-that
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/tenants /var/lib/devopslings /root/answers

      # Four steps that can fail. Which of them fail is controlled by the check,
      # so the same script is exercised against each failure in turn.
      cat > /usr/local/bin/tenant-step <<'SH'
      #!/bin/bash
      # tenant-step <name> — succeeds unless /srv/tenants/fail-<name> exists.
      step=${1:-unknown}
      if [ -e "/srv/tenants/fail-$step" ]; then
        echo "tenant-step: $step failed" >&2
        exit 4
      fi
      echo "tenant-step: $step ok"
      SH
      chmod 0755 /usr/local/bin/tenant-step

      cat > /usr/local/bin/provision-tenant <<'SH'
      #!/bin/bash
      set -euo pipefail

      # 1. Inside an `if` condition. The whole point of `if` is to test a status,
      #    so `set -e` steps aside for it — including for everything the
      #    condition calls.
      if tenant-step create-db; then
        echo "provision: database ready"
      fi

      # 2. On the left of && or ||. Same rule: these are testing contexts.
      tenant-step create-schema && echo "provision: schema ready"

      # 3. `local` (or `export`, or `declare`) with a command substitution. The
      #    exit status becomes that of `local` itself, which essentially always
      #    succeeds — so the failure inside is discarded. A PLAIN assignment
      #    would have propagated it; adding `local` is what breaks it.
      make_creds() {
        local creds=$(tenant-step create-user)
        echo "provision: creds=${creds:-none}"
      }
      make_creds

      # 4. A function called as a condition. `set -e` is suspended for the whole
      #    call, all the way down, not just for the top-level command.
      seed() {
        tenant-step seed-data
        echo "provision: seeded"
      }
      if seed; then
        echo "provision: seed step returned"
      fi

      echo "provision: tenant is ready"
      SH
      chmod 0755 /usr/local/bin/provision-tenant

      rm -f /srv/tenants/fail-*

      cat > /root/questions.txt <<'Q'
      provision-tenant begins with `set -euo pipefail` and still prints
      "tenant is ready" when a step underneath it failed.

      Fix it so that if ANY of its four steps fails, the script stops there and
      exits non-zero — and when every step succeeds, it still prints
      "provision: tenant is ready" and exits 0.

      The check runs it five times: once with each of the four steps made to
      fail (create-db, create-schema, create-user, seed-data), and once with all
      four healthy. Keep the four steps and their order.
      Q

      echo "scenario ready — provision-tenant survives failures it is supposed to stop for"
      touch /srv/tenants/fail-create-db
      /usr/local/bin/provision-tenant 2>&1 | tail -3 || true
      echo "  exit status was: ${PIPESTATUS[0]:-0}"
      rm -f /srv/tenants/fail-create-db

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if [ ! -x /usr/local/bin/provision-tenant ]; then
        echo "not yet: /usr/local/bin/provision-tenant is missing or not executable"
        exit 1
      fi

      hint_for() {
        case "$1" in
          create-db)     echo "an \`if\` condition — set -e is suspended for the command being tested" ;;
          create-schema) echo "the left-hand side of && — also a testing context" ;;
          create-user)   echo "\`local x=\$(...)\` — the status is \`local\`'s, and \`local\` succeeded" ;;
          seed-data)     echo "a function used as a condition — suspended for the whole call, recursively" ;;
        esac
      }

      for step in create-db create-schema create-user seed-data; do
        rm -f /srv/tenants/fail-*
        touch "/srv/tenants/fail-$step"

        set +e
        outp=$(/usr/local/bin/provision-tenant 2>&1)
        rc=$?
        set -e

        if [ "$rc" -eq 0 ]; then
          echo "not yet: with '$step' failing, provision-tenant still exited 0"
          echo "         that step is called from $(hint_for "$step")."
          printf '%s\n' "$outp" | tail -3 | sed 's/^/           /'
          rm -f /srv/tenants/fail-*
          exit 1
        fi

        if printf '%s' "$outp" | grep -q 'tenant is ready'; then
          echo "not yet: with '$step' failing, provision-tenant exited $rc but still"
          echo "         printed 'tenant is ready' — it carried on past the failure and"
          echo "         only reported it at the end. It has to stop there."
          rm -f /srv/tenants/fail-*
          exit 1
        fi
      done

      # And the healthy path still has to work.
      rm -f /srv/tenants/fail-*
      set +e
      outp=$(/usr/local/bin/provision-tenant 2>&1)
      rc=$?
      set -e

      if [ "$rc" -ne 0 ]; then
        echo "not yet: with every step healthy, provision-tenant exited $rc"
        printf '%s\n' "$outp" | tail -5 | sed 's/^/         /'
        echo "         a script that always fails is not the fix."
        exit 1
      fi
      if ! printf '%s' "$outp" | grep -q 'tenant is ready'; then
        echo "not yet: the healthy run exited 0 but never printed 'provision: tenant is ready'"
        exit 1
      fi

      for step in create-db create-schema create-user seed-data; do
        if ! printf '%s' "$outp" | grep -q "tenant-step: $step ok"; then
          echo "not yet: the healthy run never ran the '$step' step — keep all four, in order"
          exit 1
        fi
      done

      echo "PASS — stops and fails on each of the four steps in turn, and still completes"
      echo "       cleanly when they all succeed."
---
