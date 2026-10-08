---
kind: lesson
title: "Set a timeout, and know what it bounds"
description: |
  checkout calls pricing with no timeout at all, which means "wait forever".
  Give it one, inside a 3-second budget. There are two numbers to set, not
  one, and the worst case is their sum — a config that looks right under the
  fault you are shown can still blow the budget under the one you are not.
name: set-a-timeout
slug: set-a-timeout
createdAt: "2026-10-08"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      # .env and the answer file live outside any container, so `compose down -v`
      # does not reset them; a solved attempt would otherwise stay solved.
      cat > .env <<'ENV'
      PRICING_CONNECT_TIMEOUT=0
      PRICING_READ_TIMEOUT=0
      PRICING_FALLBACK=
      ENV
      ans_dir="$DEVOPSLINGS_ROOT/scratch/set-a-timeout"
      mkdir -p "$ans_dir"
      rm -f "$ans_dir/answer.txt"

      docker compose up -d --wait >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/reset >/dev/null 2>&1 || true

      echo "scenario ready — checkout and pricing are both healthy."
      echo
      curl -fsS --max-time 5 http://127.0.0.1:18090/checkout || true
      echo
      echo
      echo "At verify time pricing's responses will be delayed by 10 seconds."
      echo "checkout must give up within 3 seconds, worst case. Configure it in"
      echo "sandboxes/chaos-stack/.env, and write your answer to"
      echo "scratch/set-a-timeout/answer.txt (from the repo root) — see the task."

  inject_fault:
    timeout_seconds: 60
    run: |
      curl -fsS -X POST http://127.0.0.1:8474/reset >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies/pricing/toxics \
        -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":10000,"jitter":0}}' \
        >/dev/null
      echo "fault injected: pricing responses delayed by 10s"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 240
    run: |
      budget=3
      ans="$DEVOPSLINGS_ROOT/scratch/set-a-timeout/answer.txt"

      # compose reads .env when it creates a container, not while one runs.
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '" ' || true; }
      ctr_val() { docker compose exec -T checkout printenv "$1" 2>/dev/null | tr -d '\r' || true; }
      want_conn=$(env_val PRICING_CONNECT_TIMEOUT); got_conn=$(ctr_val PRICING_CONNECT_TIMEOUT)
      want_read=$(env_val PRICING_READ_TIMEOUT);    got_read=$(ctr_val PRICING_READ_TIMEOUT)
      if [ "${want_conn:-0}" != "${got_conn:-0}" ] || [ "${want_read:-0}" != "${got_read:-0}" ]; then
        echo "not yet: your .env is not what the running container has."
        echo "  .env says      CONNECT_TIMEOUT='${want_conn:-}' READ_TIMEOUT='${want_read:-}'"
        echo "  container has  CONNECT_TIMEOUT='${got_conn:-}' READ_TIMEOUT='${got_read:-}'"
        echo
        echo "compose reads .env when it creates a container, not while one runs."
        echo "Apply it:  docker compose -p devopslings-chaos-stack up -d"
        exit 1
      fi

      # The timeout checkout actually applies, mirroring _timeout() in
      # app/checkout.py: either value left at 0 falls back to 3s once the other
      # is set, and both at 0 means no timeout at all.
      eff=$(awk -v c="${got_conn:-0}" -v r="${got_read:-0}" 'BEGIN {
        c += 0; r += 0
        if (c <= 0 && r <= 0) { print "none none none"; exit }
        if (c <= 0) c = 3; if (r <= 0) r = 3
        print c, r, c + r }')
      set -- $eff
      eff_conn=$1 eff_read=$2 worst=$3

      if [ ! -s "$ans" ]; then
        echo "not yet: scratch/set-a-timeout/answer.txt is missing or empty."
        echo "It needs two lines:"
        echo "  fired: <connect or read>   — which timeout the fault makes give up"
        echo "  worst_case: <seconds>      — the longest checkout can now wait on pricing"
        exit 1
      fi
      ans_fired=$(grep -Ei '^[[:space:]]*fired[[:space:]]*:' "$ans" 2>/dev/null | head -1 \
                  | cut -d: -f2- | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)
      ans_worst=$(grep -Ei '^[[:space:]]*worst_case[[:space:]]*:' "$ans" 2>/dev/null | head -1 \
                  | cut -d: -f2- | tr -d '[:space:]s' || true)
      if [ -z "$ans_fired" ] || [ -z "$ans_worst" ]; then
        echo "not yet: answer.txt needs both a 'fired:' line and a 'worst_case:' line."
        echo "Found fired='${ans_fired}' worst_case='${ans_worst}'."
        exit 1
      fi

      # One request by hand, so a rejection can show what the grader saw and
      # which timeout produced it.
      sample=$(curl -s --max-time 15 -w ' HTTP %{http_code} in %{time_total}s' \
                 http://127.0.0.1:18090/checkout 2>/dev/null | tr -d '\n' || true)

      # The worst case is a max, not a percentile: every request must come back
      # inside the budget, and "came back" includes a fast 503.
      js=$(cat <<'JS'
      import http from 'k6/http';
      import { check } from 'k6';
      export const options = {
        vus: 3,
        duration: '6s',
        thresholds: {
          http_req_duration: ['max<3000'],
          checks: ['rate==1'],
        },
      };
      export default function () {
        const res = http.get('http://checkout:8080/checkout', { timeout: '30s' });
        check(res, { 'checkout answered': (r) => r.status === 200 || r.status === 503 });
      }
      JS
      )
      k6ok=1
      out=$(printf '%s\n' "$js" | docker compose exec -T k6 k6 run --quiet - 2>&1) || k6ok=0

      if [ "$k6ok" = 0 ]; then
        printf '%s\n' "$out" | grep -E 'http_req_duration|checks' | head -4 || true
        echo
        if [ "$eff_read" = none ]; then
          echo "not yet: checkout has no timeout (CONNECT='${got_conn:-}' READ='${got_read:-}'), so it"
          echo "waited out the whole 10s fault. One request: ${sample:-no answer}"
        elif awk -v r="$eff_read" 'BEGIN { exit !(r >= 10) }'; then
          echo "not yet: checkout's read timeout is ${eff_read}s, longer than the 10s delay, so it never"
          echo "fired — the request just waited and succeeded late. A timeout bounds nothing if it"
          echo "is longer than the wait it guards against. One request: ${sample:-no answer}"
        elif awk -v r="$eff_read" -v b="$budget" 'BEGIN { exit !(r >= b) }'; then
          if [ "${got_read:-0}" = 0 ] || [ -z "${got_read:-}" ]; then
            echo "not yet: you set only the connect timeout (${got_conn}s). This fault delays the"
            echo "response, which the read timeout governs, and with READ unset checkout uses 3s —"
            echo "a request that waits the full 3s is not inside a 3s budget."
          else
            echo "not yet: checkout gives up on the response after ${eff_read}s, and the budget"
            echo "is ${budget}s — a request that waits out the read timeout has already missed it."
          fi
          echo "One request: ${sample:-no answer}"
        else
          echo "not yet: some requests took ${budget}s or more with connect=${eff_conn}s read=${eff_read}s."
          echo "One request: ${sample:-no answer}"
        fi
        exit 1
      fi

      if awk -v w="$worst" -v b="$budget" 'BEGIN { exit !(w > b + 0.001) }'; then
        echo "not yet: under this fault checkout gave up in time (${sample:-})."
        echo "But a timeout is a promise about the worst case, and yours is"
        echo "connect ${eff_conn}s + read ${eff_read}s = ${worst}s, over the ${budget}s budget: a request"
        echo "whose connect stalls waits ${eff_conn}s for that, then up to ${eff_read}s for the answer."
        if [ "${got_conn:-0}" = 0 ] || [ -z "${got_conn:-}" ]; then
          echo "PRICING_CONNECT_TIMEOUT is unset, and checkout fills it in as 3s once READ is set."
        fi
        exit 1
      fi

      # The fault is off from here: a timeout tighter than pricing's normal
      # latency turns a healthy dependency into a failing one.
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency >/dev/null 2>&1 || true
      healthy=$(curl -s --max-time 10 http://127.0.0.1:18090/checkout 2>/dev/null || true)
      if ! printf '%s' "$healthy" | grep -q '"source":"pricing"'; then
        echo "not yet: with pricing healthy again, checkout still could not get a price:"
        echo "  ${healthy:-no answer}"
        echo "connect=${eff_conn}s read=${eff_read}s is shorter than pricing takes on a good day."
        exit 1
      fi

      # The proxy accepts the connection at once and holds back the response,
      # so this fault can only ever trip the read timeout.
      if [ "$ans_fired" != read ]; then
        echo "not yet: answer.txt says 'fired: ${ans_fired}'. Under the fault, checkout answered:"
        echo "  ${sample:-no answer}"
        echo "Look at what was slow: setting up the TCP connection, or the response on it?"
        exit 1
      fi
      if ! awk -v a="$ans_worst" -v w="$worst" 'BEGIN { d = a - w; exit !(a ~ /^[0-9.]+$/ && d < 0.01 && d > -0.01) }'; then
        echo "not yet: answer.txt says 'worst_case: ${ans_worst}', but with the timeouts checkout is"
        echo "running, a request can wait at most ${eff_conn}s to connect and then ${eff_read}s for the"
        echo "response. What is the longest it can wait in total?"
        exit 1
      fi

      echo "PASS — checkout gives up on pricing within ${worst}s, worst case, and you can say why."
