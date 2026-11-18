---
kind: lesson
title: "Ten fast calls make one slow page"
description: |
  Every profile shard answers in 10ms, and its p99 is 10ms. The profile page
  calls all ten and its p99 is half a second. Nothing is broken: one call in a
  hundred is slow, and a page that makes ten calls meets one far more often
  than one time in a hundred.
name: fan-out-amplification
slug: fan-out-amplification
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.fan-out-amplification
      lesson=$1
      # .env lives outside any container, so a solved attempt would otherwise stay solved.
      cat > .env <<'ENV'
      FANOUT=sequential
      HEDGE_AFTER_MS=
      ENV
      mkdir -p answers
      rm -f answers/fan-out.txt
      cp "$lesson/files/page.js" answers/page.js
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — the profile page is on checkout:8220, its ten shards on checkout:8221."
      echo
      echo "Load-test the page (30 a second, budget p99 < 200ms):"
      echo "  docker compose exec -T k6 k6 run - < answers/page.js"
      echo
      echo "The page's settings are FANOUT and HEDGE_AFTER_MS in sandboxes/chaos-stack/.env."
      echo "Apply them with:  bash $lesson/files/deploy.sh"

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.fan-out-amplification
      lesson=$1
      ans=answers/fan-out.txt
      pct=$(grep -E '^slow_page_pct=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9.' || true)
      if [ -z "$pct" ]; then
        echo "not yet: $ans needs slow_page_pct=<n>: the percentage of pages that wait on at least"
        echo "one slow shard call, computed from the shard numbers before you measure anything."
        exit 1
      fi
      if awk -v p="$pct" 'BEGIN { exit !(p < 9.3 || p > 9.8) }'; then
        echo "not yet: slow_page_pct=$pct."
        if awk -v p="$pct" 'BEGIN { exit !(p >= 9.8 && p <= 10.2) }'; then
          echo "Ten times 1% counts a page with two slow calls twice. Work it from the other side:"
          echo "the chance that all ten calls are fast is 0.99 to the tenth."
        elif awk -v p="$pct" 'BEGIN { exit !(p <= 1.05) }'; then
          echo "That is one shard call's chance of being slow. A page makes ten calls and is slow if"
          echo "any of them is."
        else
          echo "A page is slow unless all ten of its shard calls are fast, and each one is fast 99% of"
          echo "the time."
        fi
        exit 1
      fi

      fanout=$(grep -E '^FANOUT=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)
      hedge=$(grep -E '^HEDGE_AFTER_MS=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)
      if ! bash "$lesson/files/deploy.sh" >/dev/null 2>&1; then
        echo "not yet: the page did not start with FANOUT=${fanout} HEDGE_AFTER_MS=${hedge}. Its error:"
        docker compose exec -T checkout tail -3 /srv/fan-out/page.log 2>/dev/null || true
        exit 1
      fi
      sj=$(docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 run --quiet --summary-export=/tmp/s.json /tmp/s.js >/dev/null 2>&1; cat /tmp/s.json' \
        < "$lesson/files/page.js" 2>/dev/null || true)
      p99=$(jq -r '.metrics.http_req_duration["p(99)"] // empty | round' <<<"$sj" 2>/dev/null || true)
      p50=$(jq -r '.metrics.http_req_duration["p(50)"] // empty | round' <<<"$sj" 2>/dev/null || true)
      ok=$(jq -r '.metrics.checks.value // 0' <<<"$sj" 2>/dev/null || echo 0)
      if [ -z "$p99" ]; then
        echo "not yet: the load test did not finish. Run answers/page.js yourself and read what k6 says."
        exit 1
      fi
      echo "this check measured, with FANOUT=${fanout:-sequential} HEDGE_AFTER_MS=${hedge:-0}: page p50 ${p50}ms, p99 ${p99}ms"
      if [ "$ok" != 1 ]; then
        echo "not yet: some pages failed (only $(awk -v v="$ok" 'BEGIN{printf "%.1f", v*100}')% were served)."
        echo "A page that errors is not a fast page — look at the k6 output with these settings."
        exit 1
      fi
      if [ "$p99" -ge 200 ]; then
        if [ "${hedge:-0}" = 0 ]; then
          echo "not yet: the page's p99 is still ${p99}ms. With no hedging, about one page in ten still"
          echo "waits for a 400ms shard call, whether the calls run one after another or all at once:"
          echo "parallel calls remove the sum, not the slowest call."
        else
          echo "not yet: the page's p99 is still ${p99}ms with a hedge after ${hedge}ms. A hedge helps only if"
          echo "it fires well before the slow call would have answered anyway: a fast call takes about"
          echo "10ms, a slow one 400ms."
        fi
        exit 1
      fi
      echo "PASS — slow_page_pct=$pct, and the page's p99 is ${p99}ms, inside the 200ms budget."
---
