---
kind: lesson
title: "Chaos, done properly"
description: |
  "Checkout survives losing a web node" is on the architecture diagram and
  has never been tested. Test it: a hypothesis that could turn out wrong, a
  fault with a bounded blast radius and an abort, and a conclusion that says
  what the data says, not what the diagram promised.
name: chaos-done-properly
slug: chaos-done-properly
createdAt: "2026-11-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/sre/chaos/runs
      cat > /ha/sre/chaos/load <<'PY'
      #!/usr/bin/env python3
      """load SECONDS [URL] — customer traffic: 4 clients, each a request every 50 ms.

      One line per request, as it completes: epoch seconds, HTTP status (0 when
      there was no answer at all), and the node that served it (X-Served-By).
      Default URL: http://www/.
      """
      import sys
      import threading
      import time
      import urllib.error
      import urllib.request

      secs = float(sys.argv[1])
      url = sys.argv[2] if len(sys.argv) > 2 else "http://www/"
      end = time.time() + secs
      lock = threading.Lock()


      def client():
          while time.time() < end:
              try:
                  with urllib.request.urlopen(url, timeout=2) as r:
                      code, who = r.status, r.headers.get("X-Served-By", "-")
                      r.read()
              except urllib.error.HTTPError as e:
                  code, who = e.code, e.headers.get("X-Served-By", "-")
              except Exception:
                  code, who = 0, "-"
              with lock:
                  print(f"{time.time():.3f} {code} {who}", flush=True)
              time.sleep(0.05)


      ts = [threading.Thread(target=client) for _ in range(4)]
      [t.start() for t in ts]
      [t.join() for t in ts]
      PY
      chmod +x /ha/sre/chaos/load
      cp /ha/sre/chaos/load /var/lib/devopslings/chaos-load
      cat > /var/lib/devopslings/chaos-stats.py <<'PY'
      # chaos-stats LOG TARGET — requests, success %, seconds covered, and how
      # many the target answered after the first 5 seconds.
      import sys
      rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 3]
      if not rows:
          print("0 0 0 0")
          sys.exit()
      t0 = float(rows[0][0])
      ok = sum(r[1] == "200" for r in rows)
      late = sum(r[2] == sys.argv[2] and float(r[0]) > t0 + 5 for r in rows)
      print(len(rows), f"{100 * ok / len(rows):.2f}", f"{float(rows[-1][0]) - t0:.0f}", late)
      PY
      rm -f /ha/sre/chaos/experiment /ha/sre/chaos/runs/*
      cat > /ha/sre/chaos/README <<'TXT'
      The claim:      checkout survives losing a web node.
      The tools:      node kill|start <name>     break and repair a node
                      /ha/sre/chaos/load SECS    customer traffic, one line per request
      Your experiment goes in /ha/sre/chaos/experiment. Each run writes the
      traffic it measured during the fault to /ha/sre/chaos/runs/latest.log, in
      load's format, and leaves the stack as it found it, however it ends.
      TXT
      cat > /ha/answers/chaos.txt <<'TXT'
      # The experiment and what it found. '#' starts a comment.
      target: ?       # the one node the experiment breaks
      hypothesis: ?   # what stays true while it is down, as something the data could prove wrong
      duration: ?     # seconds the fault lasts
      abort: ?        # the success rate (%) below which the experiment stops early and repairs
      observed: ?     # the success rate (%) during the fault, from runs/latest.log
      verdict: ?      # held or refuted
      TXT
      echo "scenario ready — the claim: checkout survives losing a web node."
      echo
      echo "  the setup:        /ha/sre/chaos/README"
      echo "  your experiment:  /ha/sre/chaos/experiment"
      echo "  your write-up:    /ha/answers/chaos.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      a=/ha/answers/chaos.txt
      x=/ha/sre/chaos/experiment
      log=/ha/sre/chaos/runs/latest.log
      stats=/var/lib/devopslings/chaos-stats.py
      if [ ! -f "$stats" ]; then
        echo "not yet: the scenario's files are missing. Reset the lesson."
        exit 1
      fi
      field() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | sed 's/[[:space:]]*#.*//' | head -1 || true; }
      num() { grep -oE '[0-9]+(\.[0-9]+)?' <<<"$1" | head -1 || true; }
      for k in target hypothesis duration abort observed verdict; do
        v=$(field "$k")
        if [ -z "$v" ] || [ "$v" = "?" ]; then
          echo "not yet: $k in $a is not filled in."
          exit 1
        fi
      done

      target=$(field target | tr 'A-Z' 'a-z')
      case $target in
        web1|web2) ;;
        *web1*web2*|*web2*web1*)
          echo "not yet: target is '$target'. Both web nodes down is checkout down: there is nothing to"
          echo "         learn from an experiment whose blast radius is every customer. Break one."
          exit 1 ;;
        *)
          echo "not yet: target is '$target'. The claim is about losing a web node: web1 or web2. Start with"
          echo "         the smallest blast radius that tests the claim."
          exit 1 ;;
      esac
      other=$([ "$target" = web1 ] && echo web2 || echo web1)

      h=$(field hypothesis)
      H=$(grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*%' <<<"$h" | head -1 | tr -d ' %' || true)
      if [ -z "$H" ] || awk -v h="$H" 'BEGIN { exit !(h <= 50 || h > 100) }'; then
        echo "not yet: the hypothesis is '$h'."
        echo "         Nothing that could happen in the experiment would prove it wrong. Make it a"
        echo "         success rate the data can fall short of, such as 'at least N% of requests succeed'."
        exit 1
      fi
      D=$(num "$(field duration)")
      if [ -z "$D" ] || awk -v d="$D" 'BEGIN { exit !(d < 10 || d > 300) }'; then
        echo "not yet: duration is '$(field duration)'. Between 10 seconds and 5 minutes: long enough to see the"
        echo "         system settle with the node gone, short enough that the fault is not the new normal."
        exit 1
      fi
      A=$(num "$(field abort)")
      if [ -z "$A" ] || awk -v a="$A" -v h="$H" 'BEGIN { exit !(a >= h) }'; then
        echo "not yet: abort is '$(field abort)'. It is a success rate below the hypothesis's $H%: the point"
        echo "         where the experiment has stopped teaching and started hurting customers."
        exit 1
      fi

      # The conclusion, against the data the experiment recorded.
      if [ ! -s "$log" ]; then
        echo "not yet: $log is empty or missing. Run the experiment; the conclusion comes from its data."
        exit 1
      fi
      read -r n S span late < <(python3 "$stats" "$log" "$target")
      if [ "$late" -gt 0 ]; then
        echo "not yet: $target answered $late of the requests in $log after its first 5 seconds."
        echo "         It was not down: the fault did not happen, so the run says nothing about losing it."
        exit 1
      fi
      if [ "$span" -lt $((${D%.*} * 8 / 10)) ]; then
        echo "not yet: $log covers ${span}s of traffic, and the fault was to last ${D}s. Record the whole fault."
        exit 1
      fi
      O=$(num "$(field observed)")
      if [ -z "$O" ] || ! awk -v o="$O" -v s="$S" 'BEGIN { d = o - s; exit !(d <= 0.2 && d >= -0.2) }'; then
        echo "not yet: observed is '$(field observed)'; $log has $n requests, $S% answered 200."
        echo "         The conclusion has to be what the data showed."
        exit 1
      fi
      v=$(field verdict | tr 'A-Z' 'a-z')
      should=$(awk -v s="$S" -v h="$H" 'BEGIN { print (s >= h ? "held" : "refuted") }')
      if [ "$v" != "$should" ]; then
        echo "not yet: the verdict is '$v', and the data says $should: $S% succeeded against a hypothesis of $H%."
        if [ "$should" = refuted ]; then
          echo "         A refuted hypothesis is the experiment working. It found something the diagram"
          echo "         did not say; write it down as found, and fix it next."
        fi
        exit 1
      fi
      echo "conclusion: $S% of $n requests succeeded with $target down; hypothesis of $H% $should"

      # The experiment's bounds, tested by running it.
      if [ ! -x "$x" ]; then
        echo "not yet: $x is missing or not executable."
        exit 1
      fi
      cp "$log" /var/lib/devopslings/chaos-latest.saved
      repair() {
        for w in web1 web2; do node resume "$w" >/dev/null 2>&1 || true; node start "$w" >/dev/null 2>&1 || true; done
        cp /var/lib/devopslings/chaos-latest.saved "$log" 2>/dev/null || true
      }
      trap repair EXIT
      up() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://$1:8080/health" || true)" = 200 ]; }
      back_within() { for _ in $(seq $(($2 * 2))); do up "$1" && return 0; sleep 0.5; done; return 1; }
      both_up() { back_within web1 30 && back_within web2 30 && sleep 3; }
      both_up

      # Stopped part-way, as an operator would with Ctrl-C.
      "$x" > /var/lib/devopslings/chaos-run1 2>&1 &
      pid=$!
      sleep 8
      kill -INT "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      if ! back_within "$target" 20; then
        echo "not yet: the grader started your experiment and stopped it 8 seconds in. 20 seconds later"
        echo "         $target was still down. An experiment that is interrupted has to repair what it broke;"
        echo "         otherwise the blast radius is however long it takes someone to notice. A trap on INT"
        echo "         and TERM."
        exit 1
      fi
      echo "interrupted after 8s: $target repaired"
      both_up

      # The world gets worse during the experiment: the other node fails too.
      "$x" > /var/lib/devopslings/chaos-run2 2>&1 &
      pid=$!
      sleep 6
      node kill "$other" >/dev/null
      t=$SECONDS
      if ! back_within "$target" 25; then
        kill -TERM "$pid" 2>/dev/null || true
        echo "not yet: 6 seconds into your experiment the grader killed $other too, and every request failed."
        echo "         25 seconds later $target was still down, so the experiment carried on with"
        echo "         checkout at 0%. An abort condition is checked while the fault is in place, and ends it:"
        echo "         watch the success rate as the traffic comes in, and repair when it drops below $A%."
        exit 1
      fi
      echo "breach: $other lost too; the experiment aborted and repaired $target after $((SECONDS - t))s"
      node start "$other" >/dev/null
      for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -TERM "$pid" 2>/dev/null || true
      echo
      echo "PASS — a falsifiable hypothesis, one node at a time, an abort that works, and a conclusion that matches the data."
---
