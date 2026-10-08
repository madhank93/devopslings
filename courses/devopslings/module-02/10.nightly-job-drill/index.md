---
kind: lesson
title: "the nightly settlement said done, and finance cannot pay from it"
description: |
  settle-nightly logged "done" and exited 0, and last night's settlement report
  is wrong. That is the whole ticket, every time — because the fault is drawn at
  random from five, each a different way a script that works lies about having
  worked: a filename with a space, a masked pipeline, a suspended set -e, an
  interrupted run trusted by its retry, a step that is not safe to run twice.
name: nightly-job-drill
slug: nightly-job-drill
createdAt: "2026-09-29"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      rm -rf /srv/settle /var/lib/settle-drill /var/log/settle /root/answers/triage.md
      rm -f /usr/local/bin/settle-nightly /usr/local/bin/settle-rates /usr/local/bin/settle-accounts \
            /usr/local/bin/settle-chargebacks /usr/local/bin/settle-convert
      day=$(date -d yesterday +%F)
      fx=/var/lib/settle-drill/fixture
      install -d /srv/settle /var/log/settle /root/answers "$fx/upstream" "$fx/inbox/$day"

      # ---- the services the job calls ------------------------------------
      # Stand-ins for HTTP APIs. Each reads its data, and whether it is having
      # a bad night, from $SETTLE_ROOT/upstream.
      cat > /usr/local/bin/settle-rates <<'SH'
      #!/bin/bash
      # settle-rates — EUR rates, "CUR micro-euros", one per line.
      root=${SETTLE_ROOT:-/srv/settle}
      echo "settle-rates: ERROR rates-mirror.internal:8443: connection refused; falling back to primary" >&2
      cat "$root/upstream/rates.txt"
      SH

      cat > /usr/local/bin/settle-accounts <<'SH'
      #!/bin/bash
      # settle-accounts — "merchant payout-account" from the directory API, five per page.
      root=${SETTLE_ROOT:-/srv/settle}
      fail=$(cat "$root/upstream/accounts-fail-page" 2>/dev/null || true)
      page=1
      while :; do
        rows=$(sed -n "$(( (page - 1) * 5 + 1 )),$(( page * 5 ))p" "$root/upstream/accounts.txt")
        [ -n "$rows" ] || break
        if [ "$page" = "$fail" ]; then
          echo "settle-accounts: ERROR page $page: HTTP 503 Service Unavailable" >&2
          exit 22
        fi
        printf '%s\n' "$rows"
        page=$((page + 1))
      done
      SH

      cat > /usr/local/bin/settle-chargebacks <<'SH'
      #!/bin/bash
      # settle-chargebacks — "merchant cents" disputed today, to deduct from payouts.
      root=${SETTLE_ROOT:-/srv/settle}
      if [ -e "$root/upstream/chargebacks-down" ]; then
        echo "settle-chargebacks: ERROR disputes-api:443: connection reset by peer" >&2
        exit 7
      fi
      cat "$root/upstream/chargebacks.txt"
      SH

      cat > /usr/local/bin/settle-convert <<'PY'
      #!/usr/bin/env python3
      # settle-convert RATES < batch.csv — one "merchant eur_cents" line per transaction.
      import os, sys, time
      root = os.environ.get("SETTLE_ROOT", "/srv/settle")
      rates = {}
      for line in open(sys.argv[1]):
          if line.strip():
              cur, micro = line.split()
              rates[cur] = int(micro)
      try:
          lookup = float(open(f"{root}/upstream/convert-delay").read())
      except OSError:
          lookup = 0.0
      for line in sys.stdin:
          line = line.strip()
          if not line:
              continue
          tx, merchant, cents, cur = line.split(",")
          if cur not in rates:
              sys.exit(f"settle-convert: {tx}: no rate for {cur}")
          time.sleep(lookup)  # the per-transaction FX lookup
          print(merchant, int(cents) * rates[cur] // 1000000, flush=True)
      PY
      chmod 0755 /usr/local/bin/settle-*

      # ---- the data --------------------------------------------------------
      printf '%s\n' 'EUR 1000000' 'USD 921500' 'GBP 1172300' 'CHF 1063100' 'SEK 87400' > "$fx/upstream/rates.txt"
      # API order, not name order: page 2 is heron, finch, gannet.
      printf '%s\n' 'corvid PAY-1003' 'acme PAY-1001' 'egret PAY-1005' 'bluebird PAY-1002' \
        'dunlin PAY-1004' 'heron PAY-1008' 'finch PAY-1006' 'gannet PAY-1007' > "$fx/upstream/accounts.txt"
      printf '%s\n' 'bluebird 4200' 'egret 12950' 'heron 800' > "$fx/upstream/chargebacks.txt"
      python3 - "$fx/inbox/$day" <<'PY'
      import random, sys
      random.seed(11)
      merchants = "acme bluebird corvid dunlin egret finch gannet heron".split()
      currencies = ["EUR"] * 4 + ["USD", "GBP", "CHF", "SEK"]
      n = 0
      # The late amex file is named by hand every night, with a space in it.
      for name, rows in (("visa.csv", 150), ("mastercard.csv", 120), ("amex late.csv", 40)):
          with open(f"{sys.argv[1]}/{name}", "w") as f:
              for _ in range(rows):
                  n += 1
                  f.write(f"tx-{n:05d},{random.choice(merchants)},{random.randint(150, 48000)},"
                          f"{random.choice(currencies)}\n")
      PY

      # ---- the job ---------------------------------------------------------
      cat > /usr/local/bin/settle-nightly <<'SH'
      #!/bin/bash
      # settle-nightly — one night's card batches as one payout line per merchant.
      #   in:  $SETTLE_ROOT/inbox/$SETTLE_DAY/*.csv        txid,merchant,amount_cents,currency
      #   out: $SETTLE_ROOT/out/settlement-$SETTLE_DAY.csv  merchant,account,payout_cents
      # Finance pays from the out file as soon as it appears. The scheduler runs
      # the job again after a failure or a timeout.
      set -euo pipefail

      root=${SETTLE_ROOT:-/srv/settle}
      day=${SETTLE_DAY:-$(date -d yesterday +%F)}
      inbox=$root/inbox/$day
      work=$root/work/$day
      out=$root/out
      report=$out/settlement-$day.csv
      mkdir -p "$work" "$out"
      trap 'rm -f "$work"/*.part "$report.part"' EXIT

      echo "settle: $day start $(date +%T)"

      settle-rates > "$work/rates"
      settle-accounts | sort > "$work/accounts"

      load_chargebacks() {
        local cb
        cb=$(settle-chargebacks)
        printf '%s\n' "$cb" > "$work/chargebacks"
      }
      load_chargebacks

      # Converting is the slow part (one FX lookup per transaction), so a batch
      # an earlier run already converted is reused from $work.
      batches=0
      for f in "$inbox"/*.csv; do
        [ -f "$f" ] || continue
        sum=$work/$(basename "$f" .csv).sum
        if [ ! -e "$sum" ]; then
          settle-convert "$work/rates" < "$f" > "$sum.part"
          mv "$sum.part" "$sum"
        fi
        batches=$((batches + 1))
      done

      cat "$work"/*.sum | awk '{ t[$1] += $2 } END { for (m in t) print m, t[m] }' | sort > "$work/totals"

      declare -A acct=() cb=()
      while read -r m a; do
        acct[$m]=$a
      done < "$work/accounts"
      while read -r m c; do
        if [ -n "$m" ]; then cb[$m]=$(( ${cb[$m]:-0} + c )); fi
      done < "$work/chargebacks"

      {
        echo "merchant,account,payout_cents"
        while read -r m total; do
          echo "$m,${acct[$m]:-},$(( total - ${cb[$m]:-0} ))"
        done < "$work/totals"
      } > "$report.part"
      mv "$report.part" "$report"

      echo "settle: $day done, $batches batches, $(( $(wc -l < "$report") - 1 )) merchants"
      SH
      chmod 0755 /usr/local/bin/settle-nightly

      # The correct report, from the batches and the upstream data alone.
      expect() {
        cat "$1/inbox/$2"/*.csv | SETTLE_ROOT=/nonexistent settle-convert "$1/upstream/rates.txt" \
          | awk -v A="$1/upstream/accounts.txt" -v C="$1/upstream/chargebacks.txt" '
              BEGIN { while ((getline l < A) > 0) { split(l, f, " "); acct[f[1]] = f[2] }
                      while ((getline l < C) > 0) { split(l, f, " "); cb[f[1]] += f[2] } }
              { t[$1] += $2 }
              END { print "merchant,account,payout_cents"
                    for (m in t) print m "," acct[m] "," t[m] - cb[m] }' | sort
      }

      # The unbroken job agrees with the oracle before anything is broken, so a
      # scenario that failed to come up cannot pass for the seeded fault.
      t=/var/lib/settle-drill/selftest
      mkdir -p "$t/inbox"
      cp -a "$fx/upstream" "$t/"
      cp -a "$fx/inbox/$day" "$t/inbox/"
      SETTLE_ROOT=$t SETTLE_DAY=$day settle-nightly >/dev/null 2>&1
      if ! diff -q <(sort "$t/out/settlement-$day.csv") <(expect "$fx" "$day") >/dev/null; then
        echo "the unbroken job and the oracle disagree before any fault was seeded"
        exit 1
      fi
      rm -rf "$t"

      # ---- seed one fault --------------------------------------------------
      faults="split pipefail errexit trap rerun"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      python3 - "$fault" <<'PY'
      import sys
      p = "/usr/local/bin/settle-nightly"
      s = open(p).read()
      edits = {
          # The batch loop word-splits ls output; a name with a space becomes two
          # words that are not files, and the guard skips both.
          "split": [('for f in "$inbox"/*.csv; do\n',
                     'for name in $(ls "$inbox"); do\n  f=$inbox/$name\n')],
          # Without pipefail, the pipeline's status is sort's.
          "pipefail": [("set -euo pipefail\n", "set -eu\n")],
          # local's own status replaces the substitution's.
          "errexit": [("  local cb\n  cb=$(settle-chargebacks)\n",
                       "  local cb=$(settle-chargebacks)\n")],
          # Converted straight into the file the next run trusts, with nothing
          # to remove it when the run is killed.
          "trap": [('    settle-convert "$work/rates" < "$f" > "$sum.part"\n    mv "$sum.part" "$sum"\n',
                    '    settle-convert "$work/rates" < "$f" > "$sum"\n'),
                   ("trap 'rm -f \"$work\"/*.part \"$report.part\"' EXIT\n", "")],
          # Appends to the published report: a second run adds a second copy.
          "rerun": [('{\n  echo "merchant,account,payout_cents"\n  while read -r m total; do\n'
                     '    echo "$m,${acct[$m]:-},$(( total - ${cb[$m]:-0} ))"\n'
                     '  done < "$work/totals"\n} > "$report.part"\nmv "$report.part" "$report"\n',
                     '[ -s "$report" ] || echo "merchant,account,payout_cents" > "$report"\n'
                     'while read -r m total; do\n'
                     '  echo "$m,${acct[$m]:-},$(( total - ${cb[$m]:-0} ))" >> "$report"\n'
                     'done < "$work/totals"\n')],
      }
      for old, new in edits[sys.argv[1]]:
          assert s.count(old) == 1, (sys.argv[1], old)
          s = s.replace(old, new)
      open(p, "w").write(s)
      PY

      # ---- the nights it worked, then last night ----------------------------
      cp -a "$fx/upstream" /srv/settle/
      log=/var/log/settle/nightly.log
      night() {
        local rc=0
        echo "--- settle-cron $(date '+%F %T') run $1" >> "$log"
        SETTLE_DAY=$1 settle-nightly >> "$log" 2>&1 || rc=$?
        echo "--- settle-cron exit $rc" >> "$log"
      }
      for back in 3 2; do
        d=$(date -d "$back days ago" +%F)
        install -d "/srv/settle/inbox/$d"
        cp "$fx/inbox/$day/visa.csv" "$fx/inbox/$day/mastercard.csv" "/srv/settle/inbox/$d/"
        night "$d"
      done
      cp -a "$fx/inbox/$day" /srv/settle/inbox/

      up=/srv/settle/upstream
      case "$fault" in
        split|errexit|pipefail)
          [ "$fault" = pipefail ] && echo 2 > "$up/accounts-fail-page"
          [ "$fault" = errexit ] && touch "$up/chargebacks-down"
          night "$day"
          ;;
        trap)
          # The scheduler's timeout kills the run mid-batch; its retry runs clean.
          echo 0.05 > "$up/convert-delay"
          echo "--- settle-cron $(date '+%F %T') run $day" >> "$log"
          SETTLE_DAY=$day setsid settle-nightly >> "$log" 2>&1 &
          pid=$!
          for _ in $(seq 1 100); do
            pgrep -s "$pid" -f settle-convert >/dev/null && break
            sleep 0.05
          done
          sleep 0.6
          kill -TERM -- -"$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          echo "--- settle-cron exit 143 (timeout: sent TERM)" >> "$log"
          rm -f "$up/convert-delay"
          night "$day"
          ;;
        rerun)
          # On-call saw ERROR in the log and ran it again to be sure.
          night "$day"
          night "$day"
          ;;
      esac
      rm -f "$up/accounts-fail-page" "$up/chargebacks-down" "$up/convert-delay"

      if diff -q <(sort "/srv/settle/out/settlement-$day.csv") <(expect "$fx" "$day") >/dev/null 2>&1; then
        echo "the $fault fault was seeded and last night's report is still right"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # the grader's own nights, run against the repaired job.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > /var/lib/settle-drill/state
      echo "$day" > /var/lib/settle-drill/day
      sha256sum /usr/local/bin/settle-rates /usr/local/bin/settle-accounts \
        /usr/local/bin/settle-chargebacks /usr/local/bin/settle-convert > /var/lib/settle-drill/helpers
      chmod -R go-rwx /var/lib/settle-drill

      cat > /root/questions.txt <<Q
      Finance cannot pay from last night's settlement:

        /srv/settle/out/settlement-$day.csv

      It is wrong. settle-nightly logged "done" and exited 0 — see
      /var/log/settle/nightly.log. It worked on every night before this one, and
      exactly one thing in /usr/local/bin/settle-nightly is wrong — drawn at
      random from five. The services it calls (settle-rates, settle-accounts,
      settle-chargebacks, settle-convert) are healthy again this morning.

      1. Repair settle-nightly, so that on any night it either publishes a
         correct report and exits 0, or exits non-zero and publishes nothing.
         The grader runs it on nights of its own, healthy and not, through
         SETTLE_ROOT and SETTLE_DAY, so keep honouring both. Leave the four
         settle-* services as they are.

      2. Make /srv/settle/out/settlement-$day.csv right.

      3. Write /root/answers/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the command or number that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order of the
      questions, not the answer.
      Q

      echo "scenario ready — one fault seeded, last night's settlement is wrong"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      digest=$(cat /var/lib/settle-drill/state 2>/dev/null || true)
      fault=""
      for cand in split pipefail errexit trap rerun; do
        h=$(printf '%s' "$cand" | sha256sum | awk '{print $1}')
        [ "$h" = "$digest" ] && fault="$cand"
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/settle-drill/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi
      day=$(cat /var/lib/settle-drill/day)
      fx=/var/lib/settle-drill/fixture
      job=/usr/local/bin/settle-nightly

      expect() {
        cat "$1/inbox/$2"/*.csv | SETTLE_ROOT=/nonexistent settle-convert "$1/upstream/rates.txt" \
          | awk -v A="$1/upstream/accounts.txt" -v C="$1/upstream/chargebacks.txt" '
              BEGIN { while ((getline l < A) > 0) { split(l, f, " "); acct[f[1]] = f[2] }
                      while ((getline l < C) > 0) { split(l, f, " "); cb[f[1]] += f[2] } }
              { t[$1] += $2 }
              END { print "merchant,account,payout_cents"
                    for (m in t) print m "," acct[m] "," t[m] - cb[m] }' | sort
      }
      indent() { sed 's/^/         /'; }
      # Three lines from each side, so a wholesale change still shows the right answer.
      sides() { { grep '^<' "$1" | head -3 || true; grep '^>' "$1" | head -3 || true; } | indent; }

      # ---- the services are the ones that were shipped --------------------
      if ! sha256sum --quiet -c /var/lib/settle-drill/helpers >/dev/null 2>&1; then
        echo "not yet: one of the settle-* services has changed:"
        sha256sum -c /var/lib/settle-drill/helpers 2>&1 | grep -v ': OK$' | indent || true
        echo "         They stand in for other teams' APIs, which you cannot edit"
        echo "         from here. Put them back and repair the job."
        exit 1
      fi

      # ---- the symptom ----------------------------------------------------
      report=/srv/settle/out/settlement-$day.csv
      if [ ! -f "$report" ]; then
        echo "not yet: $report does not exist. Finance needs last night's report."
        exit 1
      fi
      if ! diff <(sort "$report") <(expect "$fx" "$day") > /tmp/settle-diff 2>&1; then
        echo "not yet: $report is still wrong. Sorted, against what last"
        echo "         night's batches and services add up to (< yours, > right):"
        sides /tmp/settle-diff
        exit 1
      fi

      if [ ! -x "$job" ]; then
        echo "not yet: $job is missing or not executable."
        exit 1
      fi

      # ---- the grader's own nights ----------------------------------------
      R=/var/lib/settle-drill/run
      # Converters orphaned by an earlier check would write into the new nights.
      # Not `pkill -f "$R"`: this script's own command line contains that path.
      pkill -f "settle-convert $R/" 2>/dev/null || true
      rm -rf "$R"
      mk() {
        r=$R/$1
        mkdir -p "$r/inbox/$day"
        cp -a "$fx/upstream" "$r/"
        cp "$fx/inbox/$day"/*.csv "$r/inbox/$day/"
      }
      run() {
        rc=0
        SETTLE_ROOT=$r SETTLE_DAY=$day timeout 60 "$job" > "$r/job.out" 2>&1 || rc=$?
      }
      batches() { (cd "$r/inbox/$day" && ls -Q | paste -sd ' '); }
      # A night that should settle: exit 0 and the right report.
      settled() {
        if [ "$rc" -ne 0 ]; then
          echo "not yet: on $1,"
          echo "         settle-nightly exited $rc. The end of its output:"
          tail -4 "$r/job.out" | indent
          exit 1
        fi
        if [ ! -f "$r/out/settlement-$day.csv" ]; then
          echo "not yet: on $1,"
          echo "         settle-nightly exited 0 and wrote no out/settlement-$day.csv"
          echo "         under SETTLE_ROOT=$r. It is graded through SETTLE_ROOT"
          echo "         and SETTLE_DAY, so it has to honour both."
          exit 1
        fi
        if ! diff <(sort "$r/out/settlement-$day.csv") <(expect "$r" "$day") > "$r/diff" 2>&1; then
          echo "not yet: on $1,"
          echo "         settle-nightly exited 0 and published a report that does not"
          echo "         add up. Sorted (< published, > right):"
          sides "$r/diff"
          [ -z "${2:-}" ] || printf '%s\n' "$2" | indent
          exit 1
        fi
      }
      # A night a service fails: exit non-zero and publish nothing.
      refused() {
        if [ "$rc" -eq 0 ]; then
          blank=$(grep -c '^[^,]*,,' "$r/out/settlement-$day.csv" 2>/dev/null || true)
          echo "not yet: on a night $1,"
          echo "         settle-nightly exited 0 and published a report"
          echo "         ($(( $(wc -l < "$r/out/settlement-$day.csv" 2>/dev/null || echo 1) - 1 )) merchants, ${blank:-0} with no account)."
          echo "         The service's error was in its output:"
          grep -v rates-mirror "$r/job.out" | grep -i error | head -2 | indent || true
          exit 1
        fi
        if [ -e "$r/out/settlement-$day.csv" ]; then
          echo "not yet: on a night $1,"
          echo "         settle-nightly exited $rc but out/settlement-$day.csv exists"
          echo "         anyway. Finance pays from whatever is there; a failed run"
          echo "         must not leave a report."
          exit 1
        fi
      }

      mk clean
      mv "$r/inbox/$day/amex late.csv" "$r/inbox/$day/amex-late.csv"
      run
      settled "a healthy night with batches $(batches)"
      if ! grep -q 'rates-mirror' "$r/job.out"; then
        echo "not yet: on a healthy night, settle-nightly's output no longer carries"
        echo "         settle-rates' 'ERROR rates-mirror.internal ... falling back to"
        echo "         primary'. That line is printed every night and is harmless — the"
        echo "         primary answered. Swallowing a service's stderr hides its next 503"
        echo "         with it; leave it in the log."
        exit 1
      fi

      mk spaces
      run
      settled "a healthy night with batches $(batches)" \
        "It printed: $(grep 'done,' "$r/job.out" | tail -1 || true)"

      mk accounts
      echo 2 > "$r/upstream/accounts-fail-page"
      run
      refused "settle-accounts prints page 1 and then fails (HTTP 503, exit 22)"

      mk chargebacks
      touch "$r/upstream/chargebacks-down"
      run
      refused "settle-chargebacks fails outright (exit 7, no output)"

      mk interrupted
      echo 0.05 > "$r/upstream/convert-delay"
      SETTLE_ROOT=$r SETTLE_DAY=$day setsid "$job" > "$r/job1.out" 2>&1 &
      pid=$!
      for _ in $(seq 1 100); do
        pgrep -s "$pid" -f settle-convert >/dev/null && break
        sleep 0.05
      done
      sleep 0.6
      kill -TERM -- -"$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      left=$(cd "$r" && find work out -type f -printf '%p %s bytes\n' 2>/dev/null || true)
      rm -f "$r/upstream/convert-delay"
      run
      settled "a night whose first run the timeout killed mid-batch (TERM), run again" \
        "What the killed run left behind:"$'\n'"$left"

      mk twice
      run
      run
      settled "a healthy night run twice, the second time" \
        "The published report has $(( $(wc -l < "$r/out/settlement-$day.csv") - 1 )) merchant lines; the batches have $(( $(expect "$r" "$day" | wc -l) - 1 )) merchants."

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty. Three lines:"
        echo "         cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        split)
          what="the batch loop split \$(ls) on spaces, so 'amex late.csv' became two words that were not files and was skipped"
          c_re='\b(spaces?|split|splitting|word.?splitting|unquoted|quot(e|es|ed|ing)|ifs|ls|filenames?)\b'
          e_re='\bls\b|\bbash -x\b|\bset -x\b|\bdiff\b|\bfind\b|amex late|\b2 batches\b|\bbatches\b'
          e_say="ls of the inbox (3 files) against 'done, 2 batches' in the log, or bash -x"
          d_re='\b(batch(es)?|files?|rows?|transactions?|counts?|lines?|reconcil\w*)\b'
          d_say="batches or rows settled against batches or rows in the inbox" ;;
        pipefail)
          what="settle-accounts failed on page 2 (503, exit 22) and '| sort' succeeded; without pipefail the job carried on with half the accounts"
          c_re='\b(pipefail|pipeline|pipes?|pipestatus|sort|settle-accounts|accounts|503|pagination|paged?)\b'
          e_re='\bpipestatus\b|\bsettle-accounts\b|\b503\b|\b22\b|nightly\.log|\bbash -x\b|\bset -x\b|\bblank\b|\bempty\b'
          e_say="the 503 from settle-accounts in nightly.log above 'done' and exit 0, or blank accounts in the report"
          d_re='\b(blank|empty|missing|accounts?|exit|status|errors?|stderr|503|5xx|http)\b'
          d_say="payout lines with no account, or a service's exit status or 5xx" ;;
        errexit)
          what="settle-chargebacks failed (exit 7), but 'local cb=\$(...)' has local's status, so set -e never saw it and no chargebacks were deducted"
          c_re='\b(local|set -e|errexit|chargebacks?|substitution|settle-chargebacks)\b'
          e_re='\bsettle-chargebacks\b|\bchargebacks\b|nightly\.log|\bbash -x\b|\bset -x\b|\bexit 7\b|\becho \$\?'
          e_say="the settle-chargebacks error in nightly.log above 'done' and exit 0, or bash -x"
          d_re='\b(chargebacks?|errors?|stderr|exit|status|deductions?|payouts?|totals?)\b'
          d_say="a service error in a run that exited 0, or deducted chargebacks falling to zero" ;;
        trap)
          what="the timeout killed the first run mid-batch; with no trap and no write-then-rename it left a truncated 'amex late.sum' that the retry reused"
          c_re='\.sum\b|\b(trap|interrupt\w*|kill\w*|terminated|timeouts?|timed out|partial|truncated|half|resum\w*|atomic|temp\w*|rename|mv)\b'
          e_re='\.sum\b|\bwc\b|nightly\.log|\b143\b|terminated|timeout|\bdiff\b|\bls\b'
          e_say="exit 143 in nightly.log, then wc -l of work/.../amex late.sum against the batch"
          d_re='\b(rows?|lines?|counts?|timeouts?|killed|exit|143|runtime|duration|retr(y|ies)|reconcil\w*)\b'
          d_say="a run killed by the timeout, or rows settled against rows in the inbox" ;;
        rerun)
          what="the job ran twice last night and appends its payout lines to the report, so every merchant is in it twice"
          c_re='>>|\b(idempot\w*|re-?runs?|re-?ran|twice|double\w*|append\w*|duplicat\w*|second run)\b'
          e_re='\buniq\b|nightly\.log|\bgrep -c\b|\bwc\b|duplicat\w*|twice|\bsort\b|16 merchants'
          e_say="two 'done' lines in nightly.log, the second saying 16 merchants, or sort | uniq -d on the report"
          d_re='\b(duplicat\w*|runs?|twice|counts?|rows?|lines?|merchants?|reconcil\w*|uniq\w*)\b'
          d_say="merchant lines in the report against merchants in the batches, or runs per night" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and the job now settles every"
        echo "         night the grader tried, so something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before finance did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 0 for one night', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired in the job: it settles healthy,"
      echo "       spaced, interrupted and repeated nights correctly, refuses when a"
      echo "       service fails, and still passes settle-rates' warning through."
---
