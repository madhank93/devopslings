---
kind: lesson
title: "One slow dependency takes down three healthy services"
description: |
  gateway, orders and product are healthy, and so is the network between
  them. reviews — a widget on the product page — gets slow. Within seconds
  product has no threads left, orders cannot check stock, and the gateway
  stops answering even the account page, which calls nothing at all.
name: cascading-failure
slug: cascading-failure
createdAt: "2026-10-09"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.cascading-failure
      lesson=$1

      # .env is gitignored sandbox state that outlives `compose down -v`, so it
      # is rewritten here or a solved attempt would survive a reset.
      cat > .env <<'ENV'
      GATEWAY_TO_PRODUCT_TIMEOUT=0
      GATEWAY_TO_PRODUCT_POOL=0
      GATEWAY_TO_ORDERS_TIMEOUT=0
      GATEWAY_TO_ORDERS_POOL=0
      ORDERS_TO_PRODUCT_TIMEOUT=0
      ORDERS_TO_PRODUCT_POOL=0
      PRODUCT_TO_REVIEWS_TIMEOUT=0
      PRODUCT_TO_REVIEWS_POOL=0
      ENV

      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/cascade-reviews >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
        -d '{"name":"cascade-reviews","listen":"0.0.0.0:21110","upstream":"pricing:8110"}' \
        >/dev/null 2>&1 || true
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — gateway on checkout:8113, in front of orders, product and reviews."
      echo
      for p in account product checkout; do
        printf '/%-9s ' "$p"
        docker compose exec -T checkout python3 -c \
          "import urllib.request; print(urllib.request.urlopen('http://localhost:8113/$p', timeout=5).read().decode())" \
          2>/dev/null || echo "(no answer)"
      done
      echo
      echo "At verify time reviews slows by 3s a call, 8 seconds into a 25s load test,"
      echo "and stays slow. /account and /checkout never use it and must not notice."
      echo "Set the per-hop limits in sandboxes/chaos-stack/.env — see the task."

  # Grader-owned state only: the proxy lives in toxiproxy's memory, so it is
  # recreated here, and the services are redeployed from .env so every verify
  # grades the settings as written. The slowdown itself starts inside the load
  # test, after a steady phase.
  inject_fault:
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.cascading-failure
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/cascade-reviews >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
        -d '{"name":"cascade-reviews","listen":"0.0.0.0:21110","upstream":"pricing:8110"}' >/dev/null
      bash "$1/files/deploy.sh" >/dev/null 2>&1 || true
      echo "fault armed: reviews slows by 3s per call, 8s into the load test"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.cascading-failure
      lesson=$1
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }

      for row in "pricing reviews 8110" "checkout product 8111" "checkout orders 8112" "checkout gateway 8113"; do
        set -- $row
        if ! docker compose exec -T "$1" python3 -c \
            "import urllib.request; urllib.request.urlopen('http://localhost:$3/health', timeout=2)" \
            >/dev/null 2>&1; then
          echo "not yet: $2 did not start with the settings in .env. Its log:"
          docker compose exec -T "$1" tail -n 5 "/srv/cascading-failure/$2.log" 2>/dev/null || true
          exit 1
        fi
      done

      rc=0
      out=$(docker compose exec -T k6 k6 run --quiet --log-output=none - \
            < "$lesson/files/cascade.js" 2>&1) || rc=$?

      val() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2 || true; }
      pct() { awk -v r="${1:-0}" 'BEGIN { printf "%.1f%%", r * 100 }'; }
      below() { awk -v a="${1:-0}" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
      a_ok=$(val account_ok); a95=$(val account_p95)
      c_ok=$(val checkout_ok); c95=$(val checkout_p95)
      p_ok=$(val product_ok); p95=$(val product_p95); rv=$(val reviews_before)
      sg=$(val starved_gateway); so=$(val starved_orders); sp=$(val starved_product)

      if [ -z "$a_ok" ]; then
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test did not finish, so there is nothing to grade — output above."
        exit 1
      fi
      echo "/account  — answered: $(pct "$a_ok"), p95: ${a95}ms"
      echo "/checkout — answered: $(pct "$c_ok"), p95: ${c95}ms"
      echo "/product  — answered: $(pct "$p_ok"), p95: ${p95}ms; with reviews before the fault: $(pct "$rv")"
      echo "requests that waited over 0.5s for a thread — gateway: ${sg}, orders: ${so}, product: ${sp}"
      echo

      if [ "$rc" -eq 0 ]; then
        echo "PASS — reviews was slow, the product page went without it, and nothing else noticed."
        exit 0
      fi

      rt=$(env_val PRODUCT_TO_REVIEWS_TIMEOUT); rp=$(env_val PRODUCT_TO_REVIEWS_POOL)
      : "${rt:=0}" "${rp:=0}"
      above=""
      for k in GATEWAY_TO_PRODUCT GATEWAY_TO_ORDERS ORDERS_TO_PRODUCT; do
        for s in TIMEOUT POOL; do
          v=$(env_val "${k}_$s")
          if [ -n "$v" ] && [ "$v" != 0 ]; then above="$above ${k}_$s=$v"; fi
        done
      done

      if below "$rv" 0.97; then
        echo "not yet: before reviews slowed down, only $(pct "$rv") of product pages had reviews."
        if awk -v t="$rt" 'BEGIN { exit !(t + 0 > 0 && t + 0 < 0.3) }'; then
          echo "One lookup in ten takes 300ms on a normal day, and PRODUCT_TO_REVIEWS_TIMEOUT=$rt"
          echo "abandons every one of them. A timeout has to sit above normal, not at the fault."
        elif [ "${rp:-0}" -gt 0 ] && [ "$rp" -lt 6 ]; then
          echo "PRODUCT_TO_REVIEWS_POOL=$rp refuses a call that finds it full. On a normal day"
          echo "about two reviews calls are in flight and bursts go higher, so some healthy"
          echo "lookups find all $rp slots taken. Size the pool to the normal day first."
        else
          echo "Something above is failing calls that a healthy reviews would have answered."
        fi
      elif below "$a_ok" 0.99 || below "$c_ok" 0.99 || ! below "$a95" 500 || ! below "$c95" 500; then
        if [ "${sp:-0}" -gt 0 ] && { [ "$rp" = 0 ] || [ "$rp" -ge 8 ]; }; then
          echo "not yet: product ran out of threads, and everything that calls it went with it."
          if [ "$rp" != 0 ]; then
            echo "PRODUCT_TO_REVIEWS_POOL=$rp is not smaller than product's 8 threads, so reviews"
            echo "calls can still hold all of them."
          elif [ "$rt" != 0 ]; then
            echo "PRODUCT_TO_REVIEWS_TIMEOUT=$rt bounds each call, not how many are waiting:"
            echo "40 pages a second each held ${rt}s want $(awk -v t="$rt" 'BEGIN { printf "%d", 40 * t + 0.5 }')"
            echo "threads, and product has 8. It cannot go lower without cutting off the normal 300ms lookups."
          elif [ -n "$above" ]; then
            echo "Your limits are on the hops above product:$above."
            echo "They decide how long a caller waits, but product's own threads were still held"
            echo "by reviews, and orders' stock checks queued behind them for a thread."
          else
            echo "Nothing limits what product spends on reviews: 40 pages a second, each held 3s,"
            echo "want 120 threads. orders' stock checks queue behind them, then the gateway's"
            echo "threads fill with requests waiting on both, and /account waits behind those."
          fi
        else
          echo "not yet: product kept its threads, but /checkout or /account still failed."
          echo "The limits on the hops above it were:${above:- none}. A limit that refuses or"
          echo "abandons healthy calls turns a protected route into a failing one."
        fi
      elif below "$p_ok" 0.95; then
        echo "not yet: the healthy routes held, but only $(pct "$p_ok") of product pages rendered."
        echo "product renders a page without reviews when the call fails; something above it"
        echo "is failing the page itself. Limits above product:${above:- none}."
      else
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test failed a threshold not covered above — output above."
      fi
      exit 1
---
