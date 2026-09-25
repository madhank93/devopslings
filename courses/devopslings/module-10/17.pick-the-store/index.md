---
kind: lesson
title: "four workloads, one store each"
description: |
  Every one of these could be made to work in the Postgres you already run, and
  two of them should not be. Four workloads, one store each, and the grader
  checks the reason — because a right answer for the wrong reason picks the
  wrong store on the fifth workload.
name: pick-the-store
slug: pick-the-store
createdAt: "2026-09-24"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e
      install -d reqs answers

      cat > reqs/case-1-ratelimit.md <<'CASE'
      # Case 1 — the rate limiter

      Every API request increments a counter keyed on (api key, current minute)
      and reads it back to decide whether to reject the request. Integers, no
      structure. Keys stop mattering an hour after they are written; about two
      million are live at any moment.

      Peak: 60,000 requests/second. The budget for the whole check is one
      millisecond, inside the request path.

      You already run Postgres and it has spare capacity.

      If the entire store were lost this afternoon, every client would get a
      fresh allowance and the system would keep serving. Nobody would need to be
      told.
      CASE

      cat > reqs/case-2-ledger.md <<'CASE'
      # Case 2 — the ledger

      Double-entry. Every transfer writes two rows — one debit, one credit — and
      both must land or neither. The support tool reads the account balance a
      moment after the transfer and has to see it.

      Entries are append-only: once written, a row is never updated and never
      deleted. Twelve months live, about 120 million rows.

      Volume is 400 writes/second and will not grow by more than double.
      CASE

      cat > reqs/case-3-per-customer-slo.md <<'CASE'
      # Case 3 — the per-customer SLO dashboard

      Product wants p99 latency broken down by customer and endpoint, over the
      last 24 hours, for any one of 200,000 customers across 30 endpoints.

      The obvious plan was to add a `customer` label to the request-duration
      metric that already exists. Staging fell over at two million series.

      The underlying events are four million a day, kept 90 days. The dashboard
      is interactive: somebody types a customer id and waits for the answer, so
      a query that takes a minute is not an answer.
      CASE

      cat > reqs/case-4-devices.md <<'CASE'
      # Case 4 — the device fleet

      Five thousand devices, forty sensors each, one sample a second: 200,000
      samples a second, every one a timestamp and a float.

      A sample is never updated after it is written. Retention is 13 months,
      after which it is dropped a day at a time.

      Every query is an aggregate over a time range — hourly means for one
      device's one sensor, or a fleet-wide p95 for a day. Nobody ever asks for
      an individual sample.

      The tags are device id and sensor name. Both are bounded: the fleet grows
      by hundreds a year and the sensor list is fixed in firmware.
      CASE

      cat > answers/verdict.md <<'ANS'
      # One line per case. Replace every ? with your answer.
      #
      #   store=    postgres | redis | timeseries | objectstore
      #   because=  accesspattern | consistency | durability | cardinality
      #
      # Pick the constraint that actually decides it — the one that would still
      # decide it if everything else in the case changed. "It scales better" is
      # not one of the tokens, and it is not a reason.
      #
      # A store may be right more than once. A store may be right none of the
      # times.

      case-1: store=? because=?
      case-2: store=? because=?
      case-3: store=? because=?
      case-4: store=? because=?
      ANS

      cat > questions.txt <<'Q'
      Four workloads, in reqs/. Each one needs a store. For each, pick the store
      and name the constraint that decided it.

        cat reqs/case-1-ratelimit.md

      Write your answers in answers/verdict.md, which has the four lines and the
      allowed values already.

      Two of these four are the same store. One of them is a workload that looks
      exactly like the workload beside it and is not.

      Nothing needs to be installed or configured. This is graded on the
      decisions and the reasons.
      Q

      echo "scenario ready — four cases in reqs/, answers in answers/verdict.md"
      ls reqs | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      ans=answers/verdict.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      fail=0
      while read -r n want_store want_token; do
        line=$(grep -E "^case-$n:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'case-$n:' line in $ans"
          exit 1
        fi

        gs=$(printf '%s' "$line" | sed -n 's/.*store=\([A-Za-z0-9]*\).*/\1/p'   | tr 'A-Z' 'a-z')
        gt=$(printf '%s' "$line" | sed -n 's/.*because=\([A-Za-z]*\).*/\1/p'    | tr 'A-Z' 'a-z')

        if [ -z "$gs" ] || [ "$gs" = "?" ]; then
          echo "not yet: case-$n has no store — it must be one of the four tokens"
          exit 1
        fi
        case "$gs" in
          postgres|redis|timeseries|objectstore) ;;
          *) echo "not yet: case-$n says store='$gs', which is not one of the four tokens"; exit 1 ;;
        esac
        if [ -z "$gt" ] || [ "$gt" = "?" ]; then
          echo "not yet: case-$n has no 'because=' token"
          exit 1
        fi
        case "$gt" in
          accesspattern|consistency|durability|cardinality) ;;
          *) echo "not yet: case-$n uses '$gt', which is not one of the four tokens"; exit 1 ;;
        esac

        if [ "$gs" != "$want_store" ]; then
          fail=1
          echo "not yet: case-$n — you said $gs."
          case "$n" in
            1) echo "         Postgres can serve this, and the case says so. Work out what a"
               echo "         committed write costs against a one millisecond budget at 60,000"
               echo "         a second, then read the last paragraph again and ask what you"
               echo "         are being told you are allowed to give up." ;;
            2) echo "         Append-only and never updated describes three of the four"
               echo "         stores here. Look instead at the two rows that must both land,"
               echo "         and at the read that follows immediately and must see them." ;;
            3) echo "         It is latency over time, so a metrics store is the obvious"
               echo "         reach — and staging already told you what happens. Count the"
               echo "         series: 200,000 customers times 30 endpoints, times a bucket"
               echo "         per histogram boundary." ;;
            4) echo "         Count the rows before reaching for a general-purpose store:"
               echo "         200,000 a second for 13 months, never updated, never read one"
               echo "         at a time, and dropped a whole day at once." ;;
          esac
        elif [ "$gt" != "$want_token" ]; then
          fail=1
          echo "not yet: case-$n — the store is right, '$gt' is not the constraint that"
          echo "         decided it."
          case "$n" in
            1) echo "         Plenty here points at an in-memory store. Only one line of the"
               echo "         case makes it safe: the one that says what happens if the whole"
               echo "         thing is lost. Without that line the answer changes." ;;
            2) echo "         The volume is modest, the rows are small, and nothing is"
               echo "         updated. What is left is the pair of rows that must land"
               echo "         together and the read that must see them the moment they do." ;;
            3) echo "         Case 4 has the same shape — a number over time, aggregated over"
               echo "         a range — and it goes in the metrics store. The difference"
               echo "         between the two cases is one number, and it is the one staging"
               echo "         fell over at." ;;
            4) echo "         Compare it to case 3, which has the same numbers over time and"
               echo "         a different answer. Here the tags are bounded, so that is not"
               echo "         what decides it. What decides it is what every query asks for"
               echo "         and what no query asks for." ;;
          esac
        fi
      done <<'EXPECT'
      1 redis durability
      2 postgres consistency
      3 postgres cardinality
      4 timeseries accesspattern
      EXPECT

      if [ "$fail" -ne 0 ]; then
        exit 1
      fi

      echo "PASS — four stores chosen and four constraints named, including the two"
      echo "       workloads that look alike and do not go in the same place."
