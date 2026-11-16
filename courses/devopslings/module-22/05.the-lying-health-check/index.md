---
kind: lesson
title: "The health check that lies"
description: |
  web1 has lost its database, and HAProxy keeps sending it half the orders,
  because web1's health check says 200. Make the check tell the truth: a node
  that cannot do its job leaves rotation, and comes back by itself when it
  can again.
name: the-lying-health-check
slug: the-lying-health-check
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
      node cut web1 back >/dev/null
      sleep 4
      echo "scenario ready — web1 has been cut off from the back network, where the database is."
      echo
      for i in 1 2 3 4; do curl -s --max-time 5 -X POST http://www/orders; done
      echo
      echo "and yet, as HAProxy sees it:"
      curl -s 'http://lb1:8404/stats;csv' | cut -d, -f1,2,18 | grep '^app,web'
      curl -s http://web1:8080/health
      node heal web1 back >/dev/null
      echo
      echo "(web1 is reconnected now; 'node cut web1 back' to see it again)"
      echo
      echo "  the check HAProxy calls:  /ha/app/health.py"
      echo "  the load balancer:        /ha/haproxy.cfg"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      cut=""
      trap '[ -n "$cut" ] && node heal web1 back >/dev/null 2>&1; true' EXIT

      status() {
        curl -fsS --max-time 2 "http://$2:8404/stats;csv" 2>/dev/null \
          | awk -F, -v s="$1" '$1 == "app" && $2 == s { print $18 }' || true
      }
      wait_status() {  # wait_status <server> <UP|DOWN> <seconds>
        local _
        for _ in $(seq "$3"); do
          case "$(status "$1" lb1)/$(status "$1" lb2)" in "$2"*/"$2"*) return 0 ;; esac
          sleep 1
        done
        return 1
      }

      if ! grep -Eq '^[[:space:]]*option[[:space:]]+httpchk' /ha/haproxy.cfg; then
        echo "not yet: /ha/haproxy.cfg has no 'option httpchk', so HAProxy only checks that"
        echo "the port is open and never asks /health at all."
        exit 1
      fi

      for n in web1 web2; do
        if ! wait_status "$n" UP 15; then
          echo "not yet: with the database reachable, lb1 lists $n as '$(status "$n" lb1)'."
          echo "/health on $n answers: $(curl -s --max-time 3 "http://$n:8080/health" || true)"
          echo "A check that fails on a healthy node takes capacity away for nothing."
          exit 1
        fi
      done
      echo "both nodes UP with the database reachable"

      cut=1
      node cut web1 back >/dev/null
      if ! wait_status web1 DOWN 10; then
        body=$(curl -s --max-time 5 -w ' (%{http_code})' http://web1:8080/health | tr -d '\n' || true)
        echo "not yet: web1 cannot reach the database, and 10 seconds later lb1 still lists it"
        echo "as '$(status web1 lb1)'. Its /health answers: $body"
        echo "That is the check saying the process is up. HAProxy needs to know whether"
        echo "the node can serve a request, and every request here needs the database."
        exit 1
      fi
      fails=0
      for _ in $(seq 20); do
        curl -fsS -o /dev/null --max-time 5 -X POST http://www/orders || fails=$((fails + 1))
      done
      if [ "$fails" -gt 0 ]; then
        echo "not yet: web1 is out of rotation, but $fails of 20 orders through www still failed."
        exit 1
      fi
      echo "web1 lost its database: out of rotation, 20 of 20 orders went to web2"

      node heal web1 back >/dev/null
      cut=""
      if ! wait_status web1 UP 20; then
        echo "not yet: web1 has its database back, and 20 seconds later lb1 still lists it as"
        echo "'$(status web1 lb1)'. /health answers: $(curl -s --max-time 3 http://web1:8080/health || true)"
        echo "A check has to report the node as it is now, not remember that it once failed."
        exit 1
      fi
      echo "web1 reconnected: back in rotation"
      echo
      echo "PASS — the check reports whether the node can do its job."
