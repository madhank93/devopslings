---
kind: lesson
title: "VIP failover, and the four seconds nobody measured"
description: |
  www is an address that only lb1 knows how to hold. Give lb2 a keepalived
  config so it takes the address when lb1 dies — then measure how long that
  takes, and get it inside the budget without ever letting both load
  balancers hold the address at once.
name: vip-failover
slug: vip-failover
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
      cat > /ha/answers/failover.txt <<'TXT'
      # With keepalived on both load balancers and advert_int left at 1, pause
      # the node holding www and measure how many seconds www stops answering
      # (gapwatch reports it as longest_gap). Write that number here, before
      # you tune anything.
      measured_before: ?
      TXT
      for _ in $(seq 20); do curl -fsS --max-time 1 http://www/ >/dev/null 2>&1 && break; sleep 0.5; done
      echo "scenario ready — www lives on lb1, and only lb1."
      echo
      echo "  lb1's VRRP config:   /ha/lb1/keepalived.conf"
      echo "  lb2's:               /ha/lb2/keepalived.conf   (does not exist yet)"
      echo "  who holds www:       docker exec devopslings-ha-lb1 ip -br addr show eth0"
      echo "  keepalived's view:   tail /ha/lb1/log /ha/lb2/log"
      echo "  measure a failover:  (sleep 2; node pause lb1) & gapwatch 10; node resume lb1"
      echo "  your measurement:    /ha/answers/failover.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      vip=172.29.22.100
      budget=2.0
      paused=""
      trap '[ -n "$paused" ] && docker unpause "devopslings-ha-$paused" >/dev/null 2>&1; true' EXIT

      holds() { docker exec "devopslings-ha-$1" ip -br addr show eth0 2>/dev/null | grep -q "$vip"; }
      holders() { for l in lb1 lb2; do holds "$l" && echo "$l"; done; true; }
      conf() { sed 's/#.*//' "/ha/$1/keepalived.conf" 2>/dev/null; }
      knob() { conf "$1" | awk -v k="$2" '$1 == k { print $2; exit }'; }

      ans=$(awk -F: '$1 ~ /^[[:space:]]*measured_before[[:space:]]*$/ { gsub(/[^0-9.]/, "", $2); print $2; exit }' /ha/answers/failover.txt 2>/dev/null || true)
      if [ -z "$ans" ]; then
        echo "not yet: measured_before in /ha/answers/failover.txt is missing or not a number."
        echo "Measure the untuned failover first: that number is half of this lesson."
        exit 1
      fi
      if ! awk -v a="$ans" 'BEGIN { exit !(a >= 2 && a <= 8) }'; then
        echo "not yet: measured_before is $ans seconds. With advert_int 1, a backup waits for"
        echo "three missed adverts plus a skew before it takes over, and gapwatch shows roughly"
        echo "3 to 5 seconds. Measure it with both nodes on advert_int 1 and lb1 paused."
        exit 1
      fi

      for l in lb1 lb2; do
        if [ ! -f "/ha/$l/keepalived.conf" ]; then
          echo "not yet: /ha/$l/keepalived.conf does not exist, so $l never takes www."
          exit 1
        fi
        if ! docker exec "devopslings-ha-$l" pgrep -x keepalived >/dev/null; then
          echo "not yet: keepalived is not running on $l. The end of /ha/$l/log says why:"
          tail -3 "/ha/$l/log" | sed 's/^/         | /'
          exit 1
        fi
      done

      # Steady state: one holder, the same one, for three seconds.
      sleep 2
      seen=""
      for _ in 1 2 3 4 5 6; do
        h=$(holders | tr '\n' ' ')
        seen="$seen|$h"
        if [ "$(wc -w <<<"$h")" -ne 1 ]; then break; fi
        sleep 0.5
      done
      h=$(holders | tr '\n' ' ')
      if [ "$(wc -w <<<"$h")" -eq 2 ]; then
        echo "not yet: lb1 and lb2 both hold $vip, with both nodes healthy. Each thinks it is"
        echo "the master, so each is answering ARP for www: a split VIP."
        for k in virtual_router_id vrrp_version advert_int; do
          a=$(knob lb1 "$k"); b=$(knob lb2 "$k")
          [ "$a" != "$b" ] && echo "$k is '${a:-default}' on lb1 and '${b:-default}' on lb2. Two VRRP routers only elect one master when they agree on it."
        done
        warn=$(grep -hiE 'must be|rounding|mismatch|invalid' /ha/lb1/log /ha/lb2/log | tail -2 || true)
        [ -n "$warn" ] && { echo "keepalived warned:"; sed 's/^/         | /' <<<"$warn"; }
        exit 1
      fi
      if [ -z "${h// /}" ]; then
        echo "not yet: neither load balancer holds $vip. Check the end of /ha/lb1/log and /ha/lb2/log."
        exit 1
      fi
      holder=${h// /}
      other=$([ "$holder" = lb1 ] && echo lb2 || echo lb1)

      # Freeze the holder: still has the address, sends nothing.
      gap=$(python3 - "$holder" <<'PY'
      import subprocess, sys, threading, time, urllib.request
      threading.Timer(1.0, lambda: subprocess.run(["docker", "pause", "devopslings-ha-" + sys.argv[1]], capture_output=True)).start()
      t0 = time.monotonic(); down = None; longest = 0.0
      while time.monotonic() - t0 < 9:
          now = time.monotonic()
          try:
              urllib.request.urlopen("http://www/", timeout=0.5).read()
              if down is not None:
                  longest = max(longest, now - down); down = None
          except Exception:
              if down is None:
                  down = now
          time.sleep(max(0, 0.05 - (time.monotonic() - now)))
      if down is not None:
          longest = max(longest, time.monotonic() - down)
      print(f"{longest:.2f}")
      PY
      )
      paused=$holder
      took=$(holds "$other" && echo yes || echo no)
      docker unpause "devopslings-ha-$holder" >/dev/null
      paused=""

      if [ "$took" != yes ]; then
        echo "not yet: with $holder frozen, $other never took $vip; www was down for ${gap}s"
        echo "and counting. Look at the end of /ha/$other/log."
        exit 1
      fi
      if ! awk -v g="$gap" -v b="$budget" 'BEGIN { exit !(g <= b) }'; then
        echo "not yet: $other took over, but www was unreachable for ${gap}s. The budget is ${budget}s."
        echo "A backup declares the master dead after 3 missed adverts plus a skew of"
        echo "(256 - priority)/256 adverts. advert_int is $(knob lb1 advert_int || true) on lb1 and $(knob lb2 advert_int || true) on lb2"
        echo "(1 when unset); intervals under a second need vrrp_version 3 in global_defs."
        exit 1
      fi
      echo "failover: $holder frozen, $other took www, longest gap ${gap}s (budget ${budget}s)"

      # After the frozen node wakes, exactly one holder again, and it stays put.
      sleep 5
      for _ in 1 2 3 4 5 6; do
        h=$(holders | tr '\n' ' ')
        if [ "$(wc -w <<<"$h")" -ne 1 ]; then
          echo "not yet: 5 seconds after $holder woke up, $vip is held by '${h:-nobody}'."
          [ "$(wc -w <<<"$h")" -eq 2 ] && echo "Both claim it: a split VIP. The waking node has to see the other's adverts and step down, or the other has to see its own."
          exit 1
        fi
        sleep 0.5
      done
      if ! curl -fsS --max-time 2 http://www/ >/dev/null; then
        echo "not yet: after the failover settled, www does not answer."
        exit 1
      fi
      echo "after $holder woke: one holder ($h), www answering"
      echo
      echo "PASS — www moves within ${budget}s, and is never held twice."
