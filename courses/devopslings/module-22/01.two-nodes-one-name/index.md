---
kind: lesson
title: "Two servers, one name"
description: |
  The shop answers at www, and every request lands on web1. web2 is an
  identical copy that has never served anyone. Put both behind the load
  balancer so they share the traffic, and so either one can stop without
  anybody noticing.
name: two-nodes-one-name
slug: two-nodes-one-name
createdAt: "2026-10-15"
timingSensitive: true

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      cat > /ha/haproxy.cfg <<'CFG'
      # Shared by lb1 and lb2. Saved changes are picked up within a second; a
      # config HAProxy rejects is logged to /ha/lb1/log and not applied.
      frontend www
          bind :80
          default_backend app

      backend app
          server web1 172.29.22.21:8080
      CFG
      sleep 2
      echo "scenario ready — www answers, and only web1 is doing the work."
      echo
      for i in 1 2 3 4; do curl -s --max-time 2 http://www/ || echo "(no answer)"; done
      echo
      echo "  load balancer config:  /ha/haproxy.cfg"
      echo "  web2 directly:         curl http://web2:8080/"
      echo "  what lb1 thinks:       curl -s 'http://lb1:8404/stats;csv' | cut -d, -f1,2,18"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      cfg=/ha/haproxy.cfg
      killed=""
      trap '[ -n "$killed" ] && docker start "devopslings-ha-$killed" >/dev/null 2>&1; true' EXIT

      # status of one server as lb1 sees it: UP, DOWN, MAINT, no check, or empty
      status() {
        curl -fsS --max-time 2 'http://lb1:8404/stats;csv' 2>/dev/null \
          | awk -F, -v s="$1" '$1 == "app" && $2 == s { print $18 }' || true
      }
      # 40 requests through www: "<code> <node> <seconds>" per line
      spread() {
        for _ in $(seq 40); do
          curl -s -o /dev/null --max-time 3 \
            -w '%{http_code} %header{x-served-by} %{time_total}\n' http://www/ || true
        done
      }

      out=$(spread)
      bad=$(printf '%s\n' "$out" | grep -vc '^200 ' || true)
      w1=$(printf '%s\n' "$out" | grep -c '^200 web1 ' || true)
      w2=$(printf '%s\n' "$out" | grep -c '^200 web2 ' || true)
      if [ "$bad" -gt 0 ]; then
        echo "not yet: $bad of 40 requests to www failed with everything running."
        echo "Codes seen: $(printf '%s\n' "$out" | cut -d' ' -f1 | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
        echo "Check /ha/lb1/log — a rejected config is reported there."
        exit 1
      fi
      for n in web1 web2; do
        c=$([ "$n" = web1 ] && echo "$w1" || echo "$w2")
        if [ "$c" -eq 0 ]; then
          line=$(grep -E "^[[:space:]]*server[[:space:]]+[^ ]+[[:space:]]+[^ ]*(${n}|172\.29\.22\.2${n#web})" "$cfg" 2>/dev/null | head -1 || true)
          echo "not yet: $n served 0 of 40 requests."
          if [ -z "$line" ]; then
            echo "It is not in the pool: no server line in $cfg points at it."
          elif printf '%s' "$line" | grep -qw backup; then
            echo "Its server line says 'backup', so it only gets traffic once every other"
            echo "server is down. That is a standby, not a second server sharing the load."
          else
            echo "It is in $cfg ($line), and lb1 reports it as '$(status "$n")'."
          fi
          exit 1
        fi
      done
      echo "both serve: web1 answered $w1, web2 answered $w2 of 40"

      for n in web1 web2; do
        killed=$n
        docker kill "devopslings-ha-$n" >/dev/null
        sleep 8
        # Sampled before the requests: what lb1 believed when they were sent.
        st=$(status "$n")
        out=$(spread)
        bad=$(printf '%s\n' "$out" | grep -vc '^200 ' || true)
        slow=$(printf '%s\n' "$out" | awk '$1 == 200 && $3 > 1 { n++ } END { print n + 0 }')
        if [ "$bad" -gt 0 ] || [ "$slow" -gt 0 ]; then
          if [ "$bad" -gt 0 ]; then
            echo "not yet: 8 seconds after $n crashed, $bad of 40 requests to www still failed."
          else
            echo "not yet: 8 seconds after $n crashed, every request succeeded, but $slow of 40"
            echo "took over a second. Each of those first tried $n, waited out the connect"
            echo "timeout, and was retried on the other server."
          fi
          case "$st" in
            "no check"|"")
              echo "lb1 still lists $n as '${st:-unknown}': nothing is checking whether it is alive,"
              echo "so HAProxy keeps sending it its share. A server line needs 'check' for"
              echo "HAProxy to notice a dead server and take it out." ;;
            UP*)
              echo "lb1 still lists $n as UP: its check has not failed often enough yet."
              echo "Look at 'inter' and 'fall' on the server line — together they set how long"
              echo "a dead server keeps receiving traffic." ;;
            *)
              echo "lb1 lists $n as $st, and requests still failed. Look at /ha/lb1/log." ;;
          esac
          exit 1
        fi
        docker start "devopslings-ha-$n" >/dev/null
        killed=""
        back=""
        for _ in $(seq 30); do
          case "$(status "$n")" in UP*) back=1; break ;; esac
          sleep 1
        done
        if [ -z "$back" ]; then
          echo "not yet: $n was out of rotation while it was dead, which is right, but 30 seconds"
          echo "after it came back lb1 still lists it as '$(status "$n")'. A recovered server"
          echo "has to rejoin by itself — 'rise' sets how many passing checks that takes."
          exit 1
        fi
        echo "$n crashed: www kept answering, all 40 under a second; it rejoined on restart"
      done

      echo
      echo "PASS — both servers share the traffic, and either one can crash."
