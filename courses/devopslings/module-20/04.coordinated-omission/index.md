---
kind: lesson
title: "The load test that waits politely for the slow answer"
description: |
  The nightly report says search's p99 is 9ms. Customers say search freezes
  for a second every few seconds. Both are measuring the same service. The
  report's load generator stops sending while search is stuck, so it records
  one slow request where production has a hundred.
name: coordinated-omission
slug: coordinated-omission
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.coordinated-omission
      lesson=$1
      rm -f answers/open.js answers/coordinated-omission.txt
      mkdir -p answers
      cp "$lesson/files/report.js" answers/report.js
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — search is on checkout:8200. Production sends it 100 requests a second."
      echo
      echo "The nightly report's load test is answers/report.js. Run it with:"
      echo "  docker compose exec -T k6 k6 run - < answers/report.js"
      echo
      echo "Write an open-model test in answers/open.js, and both p99s in"
      echo "answers/coordinated-omission.txt — see the task."

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.coordinated-omission
      lesson=$1
      ans=answers/coordinated-omission.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9.' || true; }

      if [ ! -s answers/open.js ]; then
        echo "not yet: answers/open.js is missing. It should be a k6 script that sends production's"
        echo "100 requests a second to http://checkout:8200/search whether or not search is answering."
        exit 1
      fi
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || { echo "not yet: search did not start — rerun the lesson's init."; exit 1; }

      ink6() { docker compose exec -T k6 sh -c "cat > /tmp/s.js && $1" < "$2" 2>/dev/null || true; }
      opts=$(ink6 'k6 inspect /tmp/s.js' answers/open.js)
      if ! jq -e . >/dev/null 2>&1 <<<"$opts"; then
        echo "not yet: k6 cannot load answers/open.js:"
        ink6 'k6 inspect /tmp/s.js 2>&1 | tail -3' answers/open.js
        exit 1
      fi
      executors=$(jq -r '[.scenarios // {} | .[] | .executor] | join(",")' <<<"$opts")
      if ! grep -q 'arrival-rate' <<<"$executors"; then
        echo "not yet: answers/open.js is still a closed-model test (${executors:-vus and duration})."
        echo "Each virtual user waits for its answer before it sends the next request, so while search"
        echo "is paused the test sends almost nothing — and records one slow request where production,"
        echo "whose customers do not wait for each other, has a hundred. Adding VUs does not change"
        echo "that. Use an arrival-rate executor: requests start on a schedule, not when the last one ends."
        exit 1
      fi

      run='k6 run --quiet --summary-export=/tmp/s.json --summary-trend-stats="p(50),p(99),max" /tmp/s.js >/dev/null 2>&1; cat /tmp/s.json'
      p99() { jq -r '.metrics.http_req_duration["p(99)"] // empty | round' 2>/dev/null <<<"$1" || true; }
      closed=$(p99 "$(ink6 "$run" "$lesson/files/report.js")")
      sj=$(ink6 "$run" answers/open.js)
      open=$(p99 "$sj")
      reqs=$(jq -r '.metrics.http_reqs.count // 0' <<<"$sj" 2>/dev/null || echo 0)
      if [ -z "$closed" ] || [ -z "$open" ]; then
        echo "not yet: a load test did not finish, so there is nothing to compare. Run answers/open.js"
        echo "yourself and read what k6 says."
        exit 1
      fi
      echo "this check measured — closed model (report.js): p99 ${closed}ms; your open model: p99 ${open}ms over $reqs requests"

      if [ "$reqs" -lt 1800 ]; then
        echo "not yet: answers/open.js sent $reqs requests. Production is 100 a second, and the test"
        echo "has to run at that rate for at least 20 seconds to stand in for it: at a lower rate, or"
        echo "over fewer of search's 5-second cycles, whether it catches a pause is luck."
        exit 1
      fi
      if [ "$open" -lt 400 ]; then
        echo "not yet: your open-model test measured a p99 of ${open}ms, so it did not see the pauses."
        echo "Check that it requests http://checkout:8200/search, and that it has enough VUs"
        echo "(maxVUs) to keep starting requests on schedule while a hundred are stuck."
        exit 1
      fi

      c=$(field closed_p99_ms); o=$(field open_p99_ms)
      if [ -z "$c" ] || [ -z "$o" ]; then
        echo "not yet: $ans needs both numbers, one per line: closed_p99_ms=<n> and open_p99_ms=<n>."
        exit 1
      fi
      if awk -v c="$c" 'BEGIN { exit !(c >= 400) }'; then
        echo "not yet: closed_p99_ms=$c is the length of a pause. The closed-model report's p(99) is"
        echo "the figure that says search is fast; copy that one from answers/report.js — not its max,"
        echo "and not the open test's p99."
        exit 1
      fi
      if awk -v c="$c" -v g="$closed" 'BEGIN { exit !(c > 3 * g + 20) }'; then
        echo "not yet: closed_p99_ms=$c, but report.js measures about ${closed}ms. Copy the p(99) from"
        echo "its http_req_duration line, not the max or the average."
        exit 1
      fi
      if awk -v o="$o" -v g="$open" 'BEGIN { exit !(o < 0.65 * g || o > 1.5 * g) }'; then
        echo "not yet: open_p99_ms=$o, but answers/open.js measures about ${open}ms here."
        if awk -v o="$o" 'BEGIN { exit !(o < 400) }'; then
          echo "That figure is the closed model's, or a run that missed the pauses."
        else
          echo "Copy the p(99) of http_req_duration from your own run of answers/open.js."
        fi
        exit 1
      fi
      echo "PASS — same service, two p99s: ${c}ms when the test waits for search, ${o}ms when it does not."
---
