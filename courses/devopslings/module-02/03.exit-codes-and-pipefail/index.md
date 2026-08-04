---
kind: lesson
title: "the nightly job that reports success and produces nothing"
description: |
  settle-orders exits 0 every night and the settlement file has been empty for
  four days. Nothing is wrong with the last command in the pipeline, and the
  last command in the pipeline is the only thing anyone asked.
name: exit-codes-and-pipefail
slug: exit-codes-and-pipefail
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/settle /var/lib/devopslings /root/answers
      rm -f /srv/settle/*.csv /srv/settle/*.out 2>/dev/null || true

      # The upstream extractor. It fails when the ledger it is pointed at is not
      # there — loudly, on stderr, with a non-zero exit. It is not the problem.
      cat > /usr/local/bin/fetch-ledger <<'SH'
      #!/bin/bash
      src=${1:-}
      if [ ! -s "$src" ]; then
        echo "fetch-ledger: $src: no such ledger" >&2
        exit 3
      fi
      cat "$src"
      SH
      chmod 0755 /usr/local/bin/fetch-ledger

      cat > /usr/local/bin/settle-orders <<'SH'
      #!/bin/bash
      # Pull last night's ledger, keep the settled rows, total them up.
      LEDGER=${LEDGER:-/srv/settle/ledger-$(date +%F).csv}
      OUT=/srv/settle/settlement.out

      fetch-ledger "$LEDGER" | grep ',SETTLED,' | awk -F, '{n++; t+=$4} END {printf "%d %.2f\n", n+0, t+0}' > "$OUT"

      echo "settle-orders: wrote $OUT"
      SH
      chmod 0755 /usr/local/bin/settle-orders

      # Today's ledger exists and is fine. The check supplies its own input, so
      # this is only here to make the healthy path runnable by hand.
      today=/srv/settle/ledger-$(date +%F).csv
      {
        echo 'id,ts,state,amount'
        echo 'ORD-1,2026-08-04T01:00:00Z,SETTLED,10.00'
        echo 'ORD-2,2026-08-04T01:00:00Z,PENDING,99.00'
        echo 'ORD-3,2026-08-04T01:00:00Z,SETTLED,32.50'
      } > "$today"

      cat > /root/questions.txt <<'Q'
      settle-orders has exited 0 every night for four days and
      /srv/settle/settlement.out has been empty the whole time.

      Make settle-orders report failure when any stage of its pipeline fails,
      and keep reporting success — with the correct totals — when they all work.

      The check runs your script twice:

        1. against a ledger that does not exist. It must exit NON-ZERO.
        2. against a good ledger. It must exit 0 and write the correct
           "<count> <total>" line to /srv/settle/settlement.out.

      It must not leave a misleading settlement.out behind after the failing run.
      Q

      echo "scenario ready — settle-orders exits 0 whether or not it produced anything"
      LEDGER=/srv/settle/missing.csv /usr/local/bin/settle-orders >/dev/null 2>&1 || true
      echo "  with a missing ledger, exit status was: $?"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      out=/srv/settle/settlement.out

      if [ ! -x /usr/local/bin/settle-orders ]; then
        echo "not yet: /usr/local/bin/settle-orders is missing or not executable"
        exit 1
      fi

      # 1. The failing path must fail.
      rm -f "$out"
      set +e
      LEDGER=/srv/settle/definitely-not-here.csv /usr/local/bin/settle-orders >/tmp/fail.log 2>&1
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        echo "not yet: with a ledger that does not exist, settle-orders still exited 0"
        echo "         fetch-ledger exited 3 and said so on stderr. The shell reported the"
        echo "         status of the LAST command in the pipeline, which was awk, and awk"
        echo "         succeeded at processing nothing."
        exit 1
      fi

      if [ -s "$out" ]; then
        echo "not yet: the failing run exited $rc but still wrote a settlement file:"
        sed 's/^/           /' "$out"
        echo "         a downstream reader cannot tell that from a real settlement."
        exit 1
      fi

      # 2. The healthy path must succeed, with the right numbers.
      good=/srv/settle/verify-ledger.csv
      {
        echo 'id,ts,state,amount'
        echo 'ORD-10,2026-08-04T01:00:00Z,SETTLED,100.00'
        echo 'ORD-11,2026-08-04T01:00:00Z,PENDING,5.00'
        echo 'ORD-12,2026-08-04T01:00:00Z,SETTLED,250.25'
        echo 'ORD-13,2026-08-04T01:00:00Z,FAILED,7.00'
        echo 'ORD-14,2026-08-04T01:00:00Z,SETTLED,49.75'
      } > "$good"

      rm -f "$out"
      set +e
      LEDGER="$good" /usr/local/bin/settle-orders >/tmp/ok.log 2>&1
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: with a good ledger, settle-orders exited $rc"
        sed 's/^/         /' /tmp/ok.log | head -5
        echo "         it has to fail on failure AND succeed on success — a script that"
        echo "         always exits non-zero is not an improvement."
        exit 1
      fi

      if [ ! -s "$out" ]; then
        echo "not yet: the healthy run exited 0 and wrote nothing to $out"
        exit 1
      fi

      got=$(tr -s '[:space:]' ' ' < "$out" | sed 's/^ *//; s/ *$//')
      if [ "$got" != "3 400.00" ]; then
        echo "not yet: $out says '$got', expected '3 400.00'"
        echo "         three SETTLED rows totalling 400.00."
        exit 1
      fi

      echo "PASS — fails when the pipeline fails, succeeds with '3 400.00' when it does not,"
      echo "       and leaves no settlement file behind on the failing run."
---
