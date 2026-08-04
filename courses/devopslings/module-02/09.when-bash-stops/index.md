---
kind: lesson
title: "four scripts, and which of them should not have been a script"
description: |
  Shell is the right tool more often than purists admit and the wrong one long
  after people stop noticing. Four real scripts, one verdict each, and the
  grader checks the reason as well as the answer — because picking correctly
  for the wrong reason does not transfer to the fifth script.
name: when-bash-stops
slug: when-bash-stops
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/verdict /root/answers /var/lib/devopslings

      cat > /srv/verdict/case-1-rotate.sh <<'CASE'
      #!/bin/bash
      # Nightly: compress yesterday's logs and copy them to object storage.
      # 18 lines. Runs on the log host. Has worked for three years.
      set -euo pipefail

      DAY=$(date -d yesterday +%F)
      SRC=/var/log/app
      STAGE=$(mktemp -d)
      trap 'rm -rf "$STAGE"' EXIT

      find "$SRC" -name "*-$DAY.log" -print0 \
        | xargs -0 -r -P4 gzip -9 -k -c > /dev/null

      find "$SRC" -name "*-$DAY.log.gz" -print0 \
        | xargs -0 -r -I{} cp -- {} "$STAGE/"

      aws s3 sync "$STAGE" "s3://acme-logs/$DAY/" --only-show-errors
      echo "rotate: $DAY uploaded"
      CASE

      cat > /srv/verdict/case-2-reconcile.sh <<'CASE'
      #!/bin/bash
      # Reconcile settlement files against the ledger. 380 lines; this is an
      # extract. Handles 11 currencies. Owned by finance. Runs monthly.
      set -euo pipefail

      declare -A LEDGER_BY_ID
      declare -A SETTLED_BY_ID
      declare -A FX_RATE
      declare -A DISCREPANCY

      while IFS= read -r line; do
        id=$(printf '%s' "$line"   | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
        amt=$(printf '%s' "$line"  | sed -n 's/.*"amount": *\([0-9.]*\).*/\1/p')
        ccy=$(printf '%s' "$line"  | sed -n 's/.*"currency": *"\([^"]*\)".*/\1/p')
        LEDGER_BY_ID["$id"]="$amt|$ccy"
      done < /srv/finance/ledger.jsonl

      for id in "${!LEDGER_BY_ID[@]}"; do
        IFS='|' read -r amt ccy <<< "${LEDGER_BY_ID[$id]}"
        rate=${FX_RATE[$ccy]:-1}
        base=$(printf '%s * %s\n' "$amt" "$rate" | bc -l)
        settled=${SETTLED_BY_ID[$id]:-0}
        delta=$(printf '%s - %s\n' "$base" "$settled" | bc -l)
        if [ "$(printf '%s > 0.005\n' "${delta#-}" | bc -l)" = "1" ]; then
          DISCREPANCY["$id"]=$delta
        fi
      done
      # ... 300 more lines, including a rounding rule per currency ...
      CASE

      cat > /srv/verdict/case-3-deploy.sh <<'CASE'
      #!/bin/bash
      # Deploy a release. 55 lines. Runs as root on every app host, from CI.
      # Deletes the previous release directory. No tests — every function
      # shells out, so there is nothing to call without a real host.
      set -euo pipefail

      RELEASE=$1
      APP_ROOT=/srv/app
      KEEP=3

      prepare()  { install -d "$APP_ROOT/releases/$RELEASE"; }
      unpack()   { tar -xzf "/tmp/$RELEASE.tar.gz" -C "$APP_ROOT/releases/$RELEASE"; }
      link()     { ln -sfn "$APP_ROOT/releases/$RELEASE" "$APP_ROOT/current"; }
      restart()  { systemctl restart app.service; }
      prune()    {
        ls -1dt "$APP_ROOT"/releases/*/ \
          | tail -n +$((KEEP + 1)) \
          | xargs -r rm -rf
      }

      prepare; unpack; link; restart; prune
      echo "deployed $RELEASE"
      CASE

      cat > /srv/verdict/case-4-healthcheck.sh <<'CASE'
      #!/bin/sh
      # Container health check. 12 lines. Runs inside the application image,
      # which contains the app binary, busybox sh, and nothing else — no
      # package manager, no python, no curl.
      set -eu

      read -r STATE < /proc/self/net/tcp || exit 1

      if [ ! -S /run/app.sock ]; then
        echo "socket missing" >&2
        exit 1
      fi

      if [ -f /run/app.draining ]; then
        exit 1
      fi

      exit 0
      CASE

      cat > /root/answers/verdict.md <<'TPL'
      # Fill this in. Keep the line prefixes exactly as they are.
      #
      # For each case:
      #   verdict  — shell | program
      #   because  — ONE token from:
      #                composition    it is glue between existing programs
      #                datastructures the problem needs real types and structures
      #                testing        it must be verifiable before it runs
      #                dependencies   the runtime constrains what can be installed
      #                performance    throughput or latency is the binding constraint
      #                concurrency    it must coordinate parallel work correctly
      #   cost     — one sentence: what you give up by choosing that. Required.

      case-1: verdict=? because=?
      cost-1:

      case-2: verdict=? because=?
      cost-2:

      case-3: verdict=? because=?
      cost-3:

      case-4: verdict=? because=?
      cost-4:

      # Which was the closest call, and why? The grader checks that you answered,
      # not which case you picked.
      closest-call:
      TPL

      cat > /var/lib/devopslings/verdict.key <<'KEY'
      1 shell composition
      2 program datastructures
      3 program testing
      4 shell dependencies
      KEY

      cat > /root/questions.txt <<'Q'
      Four scripts in /srv/verdict/. Read them.

      For each, decide whether it should be a shell script or a program in a
      real language, and name the ONE constraint that decided it.

      Write your answers in /root/answers/verdict.md — a template is already
      there with the allowed tokens.

      The grader checks the verdict AND the constraint. Getting the verdict right
      for the wrong reason does not pass, because the reason is the part that
      transfers to the fifth script.

      You must also state, for each case, what choosing that costs you. Every
      one of these has a downside; an answer with no downside is not an
      engineering decision.
      Q

      echo "scenario ready — four scripts in /srv/verdict/, template in /root/answers/verdict.md"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=/root/answers/verdict.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      fail=0

      while read -r n want_verdict want_token; do
        line=$(grep -E "^case-$n:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'case-$n:' line in $ans"
          exit 1
        fi

        got_verdict=$(printf '%s' "$line" | sed -n 's/.*verdict=\([A-Za-z]*\).*/\1/p' | tr 'A-Z' 'a-z')
        got_token=$(printf '%s' "$line"   | sed -n 's/.*because=\([A-Za-z]*\).*/\1/p' | tr 'A-Z' 'a-z')

        if [ -z "$got_verdict" ] || [ "$got_verdict" = "?" ]; then
          echo "not yet: case-$n has no verdict — it must be 'shell' or 'program'"
          exit 1
        fi
        if [ -z "$got_token" ] || [ "$got_token" = "?" ]; then
          echo "not yet: case-$n has no 'because=' token"
          exit 1
        fi
        case "$got_token" in
          composition|datastructures|testing|dependencies|performance|concurrency) ;;
          *) echo "not yet: case-$n uses '$got_token', which is not one of the six tokens"; exit 1 ;;
        esac

        if [ "$got_verdict" != "$want_verdict" ]; then
          echo "not yet: case-$n — you said '$got_verdict'."
          case "$n" in
            1) echo "         It is 18 lines of glue: find, xargs, gzip, aws. Every piece of"
               echo "         work is done by an existing program. Rewriting it in another"
               echo "         language means calling the same four tools with more ceremony." ;;
            2) echo "         380 lines, four associative arrays, JSON parsed with sed, and"
               echo "         currency arithmetic through bc. Look at what it is fighting." ;;
            3) echo "         It runs as root on every host and deletes directories, and"
               echo "         there is no way to exercise prune() without a real machine." ;;
            4) echo "         Read the comment about what is in the image." ;;
          esac
          fail=1
          continue
        fi

        if [ "$got_token" != "$want_token" ]; then
          echo "not yet: case-$n — the verdict '$got_verdict' is right, the reason is not."
          echo "         You said '$got_token'."
          case "$n" in
            1) echo "         Nothing here is slow, nothing is concurrent that xargs -P does not"
               echo "         already handle, and it has no dependency problem. What it IS, is"
               echo "         four existing programs joined together." ;;
            2) echo "         It is not primarily a testing or dependency problem. Look at what"
               echo "         it is emulating: maps, records, decimal arithmetic. The shell has"
               echo "         one type, and it is 'string'." ;;
            3) echo "         55 lines is not too big, and it has no unusual dependencies. The"
               echo "         problem is that it runs as root, destroys things, and cannot be"
               echo "         exercised anywhere except production." ;;
            4) echo "         12 lines is not the reason. The reason is what the image does and"
               echo "         does not contain." ;;
          esac
          fail=1
          continue
        fi

        cost=$(grep -E "^cost-$n:" "$ans" | head -1 | sed "s/^cost-$n: *//" || true)
        cost_len=$(printf '%s' "$cost" | tr -d '[:space:]' | wc -c)
        if [ "$cost_len" -lt 25 ]; then
          echo "not yet: cost-$n is missing or too short to be a real answer."
          echo "         Every one of these choices gives something up. Shell costs you"
          echo "         types, testing and error handling; a program costs you a build,"
          echo "         a runtime on the host, and people who can edit it at 3am."
          fail=1
        fi
      done < /var/lib/devopslings/verdict.key

      [ "$fail" -ne 0 ] && exit 1

      closest=$(grep -E '^closest-call:' "$ans" | head -1 | sed 's/^closest-call: *//' || true)
      closest_len=$(printf '%s' "$closest" | tr -d '[:space:]' | wc -c)
      if [ "$closest_len" -lt 40 ]; then
        echo "not yet: 'closest-call:' is missing or too short."
        echo "         Which of the four was genuinely arguable, and why? The grader does"
        echo "         not judge which one you picked — only that you committed to one."
        exit 1
      fi

      echo "PASS — four verdicts, four reasons, four stated costs, and a closest call."
      echo "       The reason is the part that transfers; the next script will not be"
      echo "       any of these four."
---
