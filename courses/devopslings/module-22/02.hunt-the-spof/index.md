---
kind: lesson
title: "Hunt the single point of failure"
description: |
  Two load balancers, two app servers, two databases, three etcd members.
  Everything is doubled, so nothing is single — or so the diagram says. Find
  every node whose loss alone takes the shop down. The grader kills each one
  in turn and compares your list with what actually happened.
name: hunt-the-spof
slug: hunt-the-spof
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

      # Which load balancer holds www, and what web2 is to HAProxy, differ from
      # one start to the next: the answer is in the running system, not in a
      # copy of someone else's.
      draw=$((RANDOM % 6))
      if [ $((draw % 2)) -eq 1 ]; then
        mkdir -p /ha/lb2
        sed 's/lb1/lb2/' /ha/lb1/keepalived.conf > /ha/lb2/keepalived.conf
        rm -f /ha/lb1/keepalived.conf
      fi
      case $((draw / 2)) in
        0) web2="server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2" ;;
        1) web2="server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2 backup" ;;
        2) web2="server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2 disabled" ;;
      esac
      cat > /ha/haproxy.cfg <<CFG
      frontend www
          bind :80
          default_backend app

      backend app
          balance roundrobin
          option httpchk GET /health
          server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2
          $web2
      CFG

      cat > /ha/answers/spof.txt <<'TXT'
      # One node name per line: every node whose loss, on its own, stops the
      # shop — www stops answering, or it stops taking orders.
      # Names: lb1 lb2 web1 web2 pg1 pg2 etcd1 etcd2 etcd3
      TXT

      # Wait until the address has settled on whichever node now holds it.
      holder=$([ $((draw % 2)) -eq 1 ] && echo lb2 || echo lb1)
      for _ in $(seq 40); do
        docker exec "devopslings-ha-$holder" ip -br addr show eth0 | grep -q 172.29.22.100 \
          && curl -fsS --max-time 1 http://www/ >/dev/null 2>&1 && break
        sleep 0.5
      done
      sleep 2
      echo "scenario ready — every box has a twin. Which ones does that not help?"
      echo
      echo "  your answer:          /ha/answers/spof.txt"
      echo "  break things:         node kill <name> / node start <name>"
      echo "  is the shop up:       curl http://www/ ; curl -X POST http://www/orders"
      echo "  the configs:          /ha/haproxy.cfg  /ha/lb1/  /ha/lb2/  /ha/app.env"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 480
    run: |
      ans=/ha/answers/spof.txt
      all="lb1 lb2 web1 web2 pg1 pg2 etcd1 etcd2 etcd3"
      killed=""
      trap '[ -n "$killed" ] && docker start "devopslings-ha-$killed" >/dev/null 2>&1; true' EXIT

      if [ ! -f "$ans" ]; then
        echo "not yet: $ans is missing."
        exit 1
      fi
      listed=$(sed 's/#.*//' "$ans" | tr ',[:upper:]' ' [:lower:]' | tr -s ' \t' '\n' | grep -v '^$' | sort -u || true)
      for n in $listed; do
        case " $all " in *" $n "*) ;; *)
          echo "not yet: '$n' in $ans is not a node. Use the names: $all"
          exit 1 ;;
        esac
      done
      if [ -z "$listed" ]; then
        echo "not yet: $ans lists no nodes. Find every node whose loss alone stops the shop."
        exit 1
      fi

      # "ok" when www answers 20 of 20 and takes an order; otherwise what broke.
      probe() {
        local fails=0 i
        for i in $(seq 20); do
          curl -fsS -o /dev/null --max-time 2 http://www/ 2>/dev/null || fails=$((fails + 1))
        done
        if [ "$fails" -gt 0 ]; then
          echo "www failed $fails of 20 requests"
          return
        fi
        if ! out=$(curl -fsS --max-time 5 -X POST http://www/orders 2>&1); then
          echo "www answered, but placing an order failed"
          return
        fi
        echo ok
      }
      healthy() {
        [ "$(docker inspect -f '{{.State.Health.Status}}' "devopslings-ha-$1" 2>/dev/null)" = healthy ]
      }
      settle() {
        local _
        for _ in $(seq 60); do
          if healthy "$1" && [ "$(probe)" = ok ]; then return 0; fi
          sleep 1
        done
        return 1
      }

      for _ in $(seq 15); do
        base=$(probe)
        [ "$base" = ok ] && break
        sleep 1
      done
      if [ "$base" != ok ]; then
        echo "not yet: with every node running, $base. The grader needs a working shop to"
        echo "break; run 'devopslings reset' if you changed the stack's configuration."
        exit 1
      fi

      truth=""
      declare -A what
      for n in $all; do
        if ! docker kill "devopslings-ha-$n" >/dev/null 2>&1; then
          echo "not yet: $n was not running when the grader went to kill it ($(docker inspect -f '{{.State.Status}}' "devopslings-ha-$n" 2>/dev/null || echo missing))."
          echo "This is the stack, not your answer: run 'devopslings reset' and verify again."
          exit 1
        fi
        killed=$n
        sleep 8
        r=$(probe)
        docker start "devopslings-ha-$n" >/dev/null
        killed=""
        if [ "$r" != ok ]; then truth="$truth $n"; what[$n]=$r; fi
        echo "killed $n: $([ "$r" = ok ] && echo 'the shop kept working' || echo "$r")"
        if ! settle "$n"; then
          echo "not yet: after $n was restarted the shop did not recover within a minute."
          echo "This is the stack, not your answer: run 'devopslings reset' and verify again."
          exit 1
        fi
      done
      echo

      vip_holders=$(for l in lb1 lb2; do [ -f "/ha/$l/keepalived.conf" ] && echo "$l"; done; true)
      web2_line=$(grep -E '^[[:space:]]*server[[:space:]]+web2\b' /ha/haproxy.cfg || true)
      bad=0
      for n in $truth; do
        grep -qx "$n" <<<"$listed" && continue
        bad=1
        echo "not yet: $n is missing from your list. With $n dead, ${what[$n]}."
        case $n in
          lb*) echo "         www is an address, and $n is the only node configured to hold it." ;;
          web*) echo "         It is the only server HAProxy sends requests to: read the other's server line." ;;
          pg1) echo "         Every write goes to pg1. pg2 is a copy, but nothing switches the app to it." ;;
        esac
      done
      for n in $listed; do
        case " $truth " in *" $n "*) continue ;; esac
        bad=1
        echo "not yet: $n is on your list, but with $n dead www answered 20 of 20 and took an order."
        case $n in
          lb*) echo "         It runs HAProxy, but www is $( [ -n "$vip_holders" ] && echo "held by $vip_holders" || echo 'not its address'). Nobody sends it traffic." ;;
          web*) if grep -qw disabled <<<"$web2_line"; then
                  echo "         web2's server line says 'disabled': it never serves, so losing it changes nothing."
                elif grep -qw backup <<<"$web2_line"; then
                  echo "         web2 is a backup server: it only serves once web1 is down, which is exactly when it is needed."
                else
                  echo "         HAProxy took it out of rotation and the other server carried the load."
                fi ;;
          pg2) echo "         The app never connects to pg2. A replica nobody depends on cannot take anything down with it." ;;
          etcd*) echo "         It is one of three members, and the shop does not use etcd at all." ;;
        esac
      done
      [ "$bad" -eq 0 ] || exit 1

      echo "PASS — your list matches what breaks:$truth"
