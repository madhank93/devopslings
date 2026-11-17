---
kind: lesson
title: "Pick an SLI"
description: |
  Three people proposed three indicators for the shop. Yesterday had one
  real incident and two scary-looking hours that hurt nobody. Write the
  indicator that drops when customers hurt and stays flat when they do not.
name: pick-an-sli
slug: pick-an-sli
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/sre
      cat > /var/lib/devopslings/sligen.py <<'PY'
      #!/usr/bin/env python3
      """sligen SEED FROM TO [KIND@HH:MM-HH:MM ...] — an HAProxy httplog for lb1.

      KIND: slow (checkout and cart take seconds), errors (they answer 503),
      scanner (a bot probing for admin pages), export (the nightly bulk export).
      """
      import math
      import random
      import sys
      from datetime import datetime, timedelta

      rng = random.Random(int(sys.argv[1]))
      day = datetime(2026, 11, 13)


      def at(hhmm):
          h, m = hhmm.split(":")
          return day + timedelta(hours=int(h), minutes=int(m))


      start, end = at(sys.argv[2]), at(sys.argv[3])
      events = []
      for spec in sys.argv[4:]:
          kind, span = spec.split("@")
          a, b = span.split("-")
          events.append((kind, at(a), at(b)))


      def active(kind, t):
          return any(k == kind and a <= t < b for k, a, b in events)


      CUSTOMER = [("GET", "/"), ("GET", "/cart"), ("POST", "/cart"), ("POST", "/orders"), ("GET", "/orders")]
      WEIGHTS = [30, 25, 15, 15, 15]
      PROBES = ["/wp-login.php", "/.env", "/admin.php", "/phpmyadmin/", "/.git/config", "/xmlrpc.php", "/backup.zip"]


      def line(t, ip, method, path, status, ta, size):
          tr = max(0, ta - 1)
          return (f"{ip}:{rng.randint(32768, 60999)} [{t:%d/%b/%Y:%H:%M:%S}.{t.microsecond // 1000:03d}] "
                  f"www app/web{rng.randint(1, 2)} 0/0/1/{tr}/{ta} {status} {size} - - ---- 4/4/0/0/0 0/0 "
                  f'"{method} {path} HTTP/1.1"')


      out = []
      t = start
      while t < end:
          for _ in range(rng.choice([0, 0, 1, 1, 1, 2, 2])):
              ts = t + timedelta(milliseconds=rng.randint(0, 999))
              method, path = rng.choices(CUSTOMER, WEIGHTS)[0]
              ip = f"198.51.100.{rng.randint(2, 254)}"
              ta = int(rng.lognormvariate(math.log(40), 0.5))
              status = 200
              hurt = path in ("/cart", "/orders")
              if hurt and active("slow", ts):
                  ta = rng.randint(2000, 9000)
              elif hurt and active("errors", ts) and rng.random() < 0.6:
                  status, ta = 503, rng.randint(1, 5)
              elif method == "POST" and path == "/cart" and rng.random() < 0.01:
                  status = 400
              elif rng.random() < 0.0005:
                  status = 500
              out.append((ts, line(ts, ip, method, path, status, ta, rng.randint(180, 900))))
          if active("scanner", t):
              for _ in range(20):
                  ts = t + timedelta(milliseconds=rng.randint(0, 999))
                  out.append((ts, line(ts, "203.0.113.66", "GET", rng.choice(PROBES), 404, rng.randint(1, 3), 153)))
          if active("export", t) and t.second % 10 == 0:
              ts = t + timedelta(milliseconds=rng.randint(0, 999))
              out.append((ts, line(ts, "172.29.22.9", "GET", f"/export?part={t:%H%M%S}", 200,
                                   rng.randint(8000, 15000), rng.randint(2_000_000, 9_000_000))))
          t += timedelta(seconds=1)

      out.sort()
      sys.stdout.write("".join(l + "\n" for _, l in out))
      PY
      python3 /var/lib/devopslings/sligen.py "$RANDOM" 00:00 23:59 \
        export@02:00-02:20 scanner@03:10-03:30 slow@14:00-14:40 > /ha/sre/lb1-2026-11-13.log
      cat > /ha/sre/complaints.txt <<'TXT'
      # Support tickets, 2026-11-13. Every ticket that day is here.
      14:06  "checkout has been spinning for ages, did my order go through?"
      14:09  "cart page won't load"
      14:11  "tried to pay three times, nothing happens"
      14:15  "is the site down?? basket just spins"
      14:22  "placed an order, got charged, no confirmation"
      14:31  "still can't check out"
      14:44  "works now, but I think I ordered twice"
      TXT
      cat > /ha/sre/candidates.txt <<'TXT'
      # Three indicators proposed for the shop. Each is computed over a window of
      # lb1's log; the incident review needs one that moves when customers hurt.
      A  error rate: the share of all responses that were not 2xx
      B  mean response time of all requests, in milliseconds
      C  the share of requests to the customer pages (/, /cart, /orders) that
         succeeded within one second
      TXT
      rm -f /ha/sre/sli
      echo "scenario ready — yesterday, as lb1 logged it, and what customers said about it."
      echo
      echo "  lb1's log for the day:   /ha/sre/lb1-2026-11-13.log   (HAProxy httplog format)"
      echo "  support tickets:         /ha/sre/complaints.txt"
      echo "  the three proposals:     /ha/sre/candidates.txt"
      echo "  your indicator:          /ha/sre/sli   (reads a log on stdin, prints one number)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      gen=/var/lib/devopslings/sligen.py
      if [ ! -f "$gen" ]; then
        echo "not yet: the scenario's log generator is missing. Reset the lesson."
        exit 1
      fi
      sli=/ha/sre/sli
      if [ ! -x "$sli" ]; then
        echo "not yet: $sli is missing or not executable. It reads an HAProxy log on stdin"
        echo "         and prints one number: the share of good events in that log."
        exit 1
      fi
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      # Fresh logs every run, at a different hour from yesterday's, so the
      # indicator is judged on what it measures and not on when things happened.
      measure() {  # measure <window> [event] — sets val
        python3 "$gen" "$RANDOM" 09:00 09:30 ${2:+"$2@09:00-09:30"} > "$tmp/$1.log"
        val=$(timeout 30 "$sli" < "$tmp/$1.log" 2>"$tmp/err" | tail -1 | tr -d ' \t\r' || true)
        if ! [[ $val =~ ^(0(\.[0-9]+)?|1(\.0+)?|\.[0-9]+)$ ]]; then
          echo "not yet: on a 30-minute window of ordinary traffic, $sli printed '${val:-nothing}'."
          if [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "         An SLI is a proportion: good events divided by valid events, between 0 and 1."
            echo "         A response time in milliseconds has no 'good' or 'bad' in it, so nothing can"
            echo "         be counted against a target."
          fi
          head -3 "$tmp/err" | sed 's/^/         | /'
          exit 1
        fi
      }
      below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

      measure normal
      if below "$val" 0.99; then
        echo "not yet: on 30 minutes of ordinary traffic, with no complaints, your SLI reads $val."
        echo "         A normal hour should read close to 1: a few 500s in a thousand is the shop's usual."
        exit 1
      fi
      echo "ordinary traffic: $val"

      measure scanner scanner
      if below "$val" 0.99; then
        echo "not yet: your SLI reads $val on a window like yesterday's 03:10-03:30, and nobody complained."
        echo "         That window is 203.0.113.66 probing /wp-login.php, /.env and friends at 20 requests a"
        echo "         second and getting 404s. Those are not customers' requests failing: no customer asked."
        exit 1
      fi
      echo "scanner probing for admin pages: $val (flat)"

      measure export export
      if below "$val" 0.99; then
        echo "not yet: your SLI reads $val on a window like yesterday's 02:00-02:20, and nobody complained."
        echo "         That is the nightly bulk export: 172.29.22.9 fetching /export, which takes 8-15 s by"
        echo "         design. It is a batch job, not a customer waiting for a page."
        exit 1
      fi
      echo "nightly export: $val (flat)"

      measure slow slow
      if ! below "$val" 0.9; then
        echo "not yet: your SLI reads $val on a window like yesterday's 14:00-14:40, when the tickets came in."
        echo "         Every response in that window was a 200: /cart and /orders took 2-9 seconds each."
        echo "         An indicator that only counts status codes cannot see a customer giving up on a"
        echo "         page that never loads."
        exit 1
      fi
      echo "checkout taking seconds: $val (dropped)"

      measure errors errors
      if ! below "$val" 0.9; then
        echo "not yet: your SLI reads $val on a window where most /cart and /orders requests answered 503"
        echo "         within a few milliseconds. Fast is not the same as served: a quick error still counts"
        echo "         against the customer."
        exit 1
      fi
      echo "checkout answering 503: $val (dropped)"
      echo
      echo "PASS — the indicator drops when customers hurt and stays flat when they do not."
---
