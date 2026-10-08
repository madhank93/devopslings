---
kind: lesson
title: "One slow endpoint starves every other endpoint"
description: |
  shop serves two routes from one thread pool: /browse never leaves the
  process, /checkout calls pricing. When pricing slows down under a checkout
  rush, /browse stops answering too — not because anything it needs is slow,
  but because every thread is parked inside a pricing call.
name: pool-exhaustion
slug: pool-exhaustion
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
      L=../../courses/devopslings/module-21/06.pool-exhaustion

      # .env is the student's file and outlives `compose down`, so it is reset
      # here. COMPOSE_FILE layers the lesson's shop service over the stack, which
      # is what lets a plain `docker compose up -d` in this directory apply it.
      cat > .env <<ENV
      COMPOSE_FILE=compose.yaml:$L/shop.compose.yaml
      SHOP_THREADS=16
      PRICING_TIMEOUT=0
      PRICING_POOL=0
      ENV

      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
        >/dev/null 2>&1 || true
      docker compose -f compose.yaml -f "$L/shop.compose.yaml" \
        up -d --wait --force-recreate shop >/dev/null 2>&1 || true

      echo "scenario ready — shop is healthy on both routes."
      echo
      curl -fsS --max-time 5 http://127.0.0.1:18091/browse || true
      echo
      curl -fsS --max-time 5 http://127.0.0.1:18091/checkout || true
      echo
      echo
      echo "At verify time pricing slows to 1.5s per call while checkout takes"
      echo "100 requests a second. /browse must stay fast, and /checkout must still"
      echo "sell what pricing can price. Configure shop in sandboxes/chaos-stack/.env."

  # Latency on the pricing proxy only. The checkout rush that turns it into
  # pool exhaustion is part of the load test, not the fault.
  inject_fault:
    timeout_seconds: 120
    run: |
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
        >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies/pricing/toxics \
        -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":1500,"jitter":0}}' \
        >/dev/null
      echo "fault injected: pricing responses delayed by 1.5s"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      L=../../courses/devopslings/module-21/06.pool-exhaustion
      dc() { docker compose -f compose.yaml -f "$L/shop.compose.yaml" "$@"; }

      if [ -z "$(dc ps -q --status running shop 2>/dev/null || true)" ]; then
        echo "not yet: the shop container is not running. Start it from"
        echo "sandboxes/chaos-stack:  docker compose -p devopslings-chaos-stack up -d shop"
        exit 1
      fi

      # compose reads .env when it creates a container, not while one runs.
      env_val() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }
      ctr_val() { dc exec -T shop printenv "$1" 2>/dev/null | tr -d '\r' || true; }
      stale=""
      for k in SHOP_THREADS PRICING_TIMEOUT PRICING_POOL; do
        want=$(env_val "$k"); got=$(ctr_val "$k")
        if [ "$want" != "$got" ]; then
          stale="$stale  $k: .env says '$want', the running container has '$got'
      "
        fi
      done
      if [ -n "$stale" ]; then
        echo "not yet: your .env is not what the running shop container has."
        printf '%s' "$stale"
        echo
        echo "Apply it:  docker compose -p devopslings-chaos-stack up -d shop"
        exit 1
      fi

      # The values shop actually runs with, mirroring shop.py's parsing.
      threads=$(ctr_val SHOP_THREADS); threads=${threads:-16}
      [ "$threads" -gt 64 ] 2>/dev/null && threads=64
      pool=$(ctr_val PRICING_POOL); pool=${pool:-0}
      tmo=$(ctr_val PRICING_TIMEOUT); tmo=${tmo:-0}

      # k6's thresholds are the grade. The script is fed on stdin because it
      # lives with the lesson, not in the stack's k6 directory.
      if out=$(dc exec -T k6 k6 run --quiet - < "$L/shop.js" 2>&1); then
        printf '%s\n' "$out" | grep -E 'route:' || true
        echo
        echo "PASS — /browse stayed fast while pricing was slow, and checkout kept selling."
        curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
          >/dev/null 2>&1 || true
        exit 0
      fi

      printf '%s\n' "$out" | grep -E 'route:|✗' || true
      echo
      browse_p95=$(printf '%s\n' "$out" | grep -F '{ route:browse }' | grep -oE 'p\(95\)=[^ ]+' \
                   | head -1 | cut -d= -f2 || true)
      sold=$(printf '%s\n' "$out" | grep -F 'route:checkout,status:200' | awk -F': ' '{print $2}' \
             | awk '{print $1}' | head -1 || true)
      : "${sold:=0}" "${browse_p95:=unknown}"
      # A timeout below pricing's current 1.5s cancels every call it makes.
      short_tmo=$(awk -v t="$tmo" 'BEGIN { print (t + 0 > 0 && t + 0 < 1.5) ? 1 : 0 }')

      if [ "$sold" -eq 0 ] && [ "$short_tmo" = 1 ]; then
        echo "not yet: checkout sold nothing. PRICING_TIMEOUT=$tmo is shorter than the 1.5s"
        echo "pricing now takes, so every call is abandoned. Pricing is slow, not broken —"
        echo "a timeout under its real latency turns a degraded route into a dead one."
      elif [ "$pool" -le 0 ] || [ "$pool" -ge "$threads" ]; then
        if [ "$pool" -gt 0 ]; then
          echo "not yet: PRICING_POOL=$pool is not smaller than the $threads worker threads, so"
          echo "checkout can still take every one of them."
        elif [ "$threads" -gt 16 ]; then
          echo "not yet: /browse p95 was $browse_p95 with $threads shared threads. 100 checkouts a"
          echo "second, each held 1.5s by pricing, want 150 threads at once — a bigger shared pool"
          echo "fills a moment later, and /browse queues behind it all the same."
        elif awk -v t="$tmo" 'BEGIN { exit !(t + 0 > 0) }'; then
          echo "not yet: /browse p95 was $browse_p95. PRICING_TIMEOUT=$tmo never fires: pricing"
          echo "answers in 1.5s, inside it, so every checkout still holds a thread for 1.5s."
          echo "A timeout bounds one request; it does not stop many from sharing one pool."
        else
          echo "not yet: /browse p95 was $browse_p95 — it never calls pricing, and it waited"
          echo "behind checkout requests for one of the $threads shared threads."
        fi
        echo "Nothing reserves any capacity for /browse."
      elif [ "$sold" -lt 40 ]; then
        echo "not yet: /browse is protected, but checkout sold only $sold in 20s (needs 40)."
        if [ "$short_tmo" = 1 ]; then
          echo "PRICING_TIMEOUT=$tmo is under pricing's 1.5s latency, so calls are abandoned."
        else
          echo "PRICING_POOL=$pool lets only $pool calls through at a time, each held 1.5s."
        fi
      else
        echo "not yet: the load test failed its thresholds with SHOP_THREADS=$threads,"
        echo "PRICING_POOL=$pool, PRICING_TIMEOUT=$tmo. /browse p95 was $browse_p95."
      fi
      exit 1
---
