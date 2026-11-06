---
kind: lesson
title: "Active-active: two nodes, one session store"
description: |
  Both app servers take traffic now, and customers' carts keep emptying
  themselves. Make a session visible from either node and survive the loss of
  the node that created it.
name: active-active
slug: active-active
createdAt: "2026-10-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      for _ in $(seq 20); do curl -fsS --max-time 1 http://www/ >/dev/null 2>&1 && break; sleep 0.5; done
      jar=$(mktemp)
      echo "scenario ready — one customer, four items, through www:"
      echo
      for item in socks hat scarf gloves; do
        curl -s -b "$jar" -c "$jar" -X POST "http://www/cart?item=$item"
      done
      rm -f "$jar"
      echo
      echo "  the app's settings:     /ha/app.env"
      echo "  the load balancer:      /ha/haproxy.cfg"
      echo "  one node directly:      curl -b sid=<sid> http://web1:8080/cart"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      killed=""
      jar=$(mktemp)
      trap 'rm -f "$jar"; [ -n "$killed" ] && docker start "devopslings-ha-$killed" >/dev/null 2>&1; true' EXIT

      items() { jq -r '.items | sort | join(",")' 2>/dev/null || echo "(no cart)"; }
      sticky() {
        grep -Eq '^[[:space:]]*(cookie[[:space:]]|stick[[:space:]-]|balance[[:space:]]+(source|hdr|uri))' /ha/haproxy.cfg \
          && echo "/ha/haproxy.cfg pins clients to one server. That hides the problem without fixing it: the session still lives in one process, and it dies with that node." || true
      }

      # One cart, written through both nodes.
      sid=$(curl -fsS -c "$jar" -X POST 'http://www/cart?item=apple' | jq -r .sid)
      curl -fsS -H "Cookie: sid=$sid" -X POST 'http://web1:8080/cart?item=bread' >/dev/null
      curl -fsS -H "Cookie: sid=$sid" -X POST 'http://web2:8080/cart?item=cheese' >/dev/null
      for n in web1 web2; do
        got=$(curl -fsS -H "Cookie: sid=$sid" "http://$n:8080/cart" | items)
        if [ "$got" != "apple,bread,cheese" ]; then
          echo "not yet: one session got 'apple' through www, 'bread' on web1 and 'cheese' on web2."
          echo "Asked directly, $n's cart for it holds: ${got:-nothing}."
          s=$(sticky)
          if [ -n "$s" ]; then echo "$s"; else
            echo "Each node keeps sessions in its own memory, so each sees only what it was told."
            echo "Look at SESSION_STORE in /ha/app.env."
          fi
          exit 1
        fi
      done
      echo "one session, written on both nodes, reads the same on both"

      # Lose the node that served the cart.
      sid=$(curl -fsS -X POST 'http://www/cart?item=pen' | jq -r .sid)
      who=$(curl -fsS -H "Cookie: sid=$sid" -X POST 'http://www/cart?item=ink' | jq -r .node)
      killed=$who
      docker kill "devopslings-ha-$who" >/dev/null
      sleep 6
      got=$(curl -fsS --max-time 3 -H "Cookie: sid=$sid" http://www/cart | items)
      docker start "devopslings-ha-$who" >/dev/null
      killed=""
      if [ "$got" != "ink,pen" ]; then
        echo "not yet: a cart with 'pen' and 'ink' was last served by $who. With $who killed,"
        echo "the same session through www shows: ${got:-nothing}."
        exit 1
      fi
      echo "$who killed: the cart was still there"
      for _ in $(seq 30); do curl -fsS --max-time 1 "http://$who:8080/ping" >/dev/null 2>&1 && break; sleep 1; done
      echo
      echo "PASS — sessions belong to the shop, not to a node."
