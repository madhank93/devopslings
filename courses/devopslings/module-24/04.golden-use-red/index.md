---
kind: lesson
title: "Golden signals, USE and RED"
description: |
  Checkout is slow and four people have four opinions, each backed by a
  graph. Two of them used the right method for their question; two used a
  method that cannot answer it. Measure the shop with RED, measure pg1 with
  USE, and name the claims that used the wrong one.
name: golden-use-red
slug: golden-use-red
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
      mkdir -p /var/lib/devopslings/use-red /ha/sre
      d=/var/lib/devopslings/use-red
      cat > "$d/sligen.py" <<'PY'
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
      python3 "$d/sligen.py" "$RANDOM" 10:00 10:30 slow@10:12-10:30 > "$d/shop-requests.log"
      python3 - "$RANDOM" > "$d/pg1-use.csv" <<'PY'
      import random, sys
      rng = random.Random(int(sys.argv[1]))
      print("time,cpu_util_pct,cpu_runqueue,mem_util_pct,swap_in_per_s,disk_util_pct,disk_queue,disk_errors,net_util_pct,net_drops")
      for i in range(180):
          m, s = divmod(i * 10, 60)
          hot = m >= 12
          print(f"10:{m:02d}:{s:02d},{rng.uniform(22, 31):.0f},{rng.uniform(0.2, 0.9):.1f},"
                f"{rng.uniform(92, 94):.0f},0,"
                f"{rng.uniform(84, 92) if hot else rng.uniform(28, 40):.0f},"
                f"{rng.uniform(11, 17) if hot else rng.uniform(0.1, 0.5):.1f},0,"
                f"{rng.uniform(6, 11):.0f},0")
      PY
      cp "$d/shop-requests.log" "$d/pg1-use.csv" /ha/sre/
      cat > /ha/sre/claims.txt <<'TXT'
      # 10:25, the incident channel. Four people, four graphs.
      A  sam:   "web1 and web2 are at 20% CPU and plenty of free memory. Customers are fine,
                 whatever is slow is somewhere else."
      B  priya: "p99 at the load balancer went from under 200 ms to seconds at 10:12, on /cart
                 and /orders."
      C  dana:  "pg1's disk queue went from under 1 to over 10 at 10:12."
      D  marco: "pg1 is serving its usual queries per second with zero errors. The database is
                 not the problem."
      TXT
      cat > /ha/answers/use-red.txt <<'TXT'
      # RED for the shop, 10:15:00 to 10:29:59, from /ha/sre/shop-requests.log.
      # Customer pages only: /, /cart, /orders.
      rate_per_second: ?
      error_percent: ?
      p99_ms: ?
      # The minute customers started to hurt, HH:MM.
      customers_hurting_since: ?

      # USE for pg1, from /ha/sre/pg1-use.csv: the one resource that is saturated.
      # cpu | memory | disk | network
      saturated_resource: ?

      # The claims in /ha/sre/claims.txt that use a method which cannot answer
      # the question they answer. Letters, space-separated.
      mismatched_claims: ?
      TXT
      echo "scenario ready — 10:25, checkout is slow, and the channel has four theories."
      echo
      echo "  the shop's requests:   /ha/sre/shop-requests.log   (HAProxy httplog, 10:00-10:30)"
      echo "  pg1's resources:       /ha/sre/pg1-use.csv         (every 10 s)"
      echo "  the four claims:       /ha/sre/claims.txt"
      echo "  your answer:           /ha/answers/use-red.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      d=/var/lib/devopslings/use-red
      a=/ha/answers/use-red.txt
      if [ ! -f "$d/shop-requests.log" ]; then
        echo "not yet: the scenario's copy of the data is missing. Reset the lesson."
        exit 1
      fi
      # rate, 5xx %, nearest-rank p99, mean, p50 of the window; then p99 over the whole half hour
      read -r RATE ERR P99 MEAN P50 < <(python3 - "$d/shop-requests.log" <<'PY'
      import math, sys
      win = []
      for l in open(sys.argv[1]):
          f = l.split()
          if f[-2].split("?")[0] not in ("/", "/cart", "/orders"):
              continue
          ta, st, ts = int(f[4].split("/")[4]), int(f[5]), f[1][13:21]
          if "10:15:00" <= ts <= "10:29:59":
              win.append((ta, st))
      def pct(xs, p):
          xs = sorted(xs)
          return xs[max(0, math.ceil(p * len(xs)) - 1)]
      t = [x for x, _ in win]
      print(len(win) / 900, 100 * sum(s >= 500 for _, s in win) / len(win),
            pct(t, .99), sum(t) / len(t), pct(t, .5))
      PY
      )
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' || true; }
      near() { awk -v x="$1" -v y="$2" -v r="$3" 'BEGIN { d = x - y; if (d < 0) d = -d; exit !(d <= r * y) }'; }
      num() {
        ans=$(val "$1" | tr -d ' %,')
        if ! [[ $ans =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          echo "not yet: $1 in $a is '${ans:-missing}'; it needs a number."
          exit 1
        fi
      }

      num rate_per_second
      if ! near "$ans" "$RATE" 0.05; then
        if near "$ans" "$(awk -v r="$RATE" 'BEGIN { print r * 60 }')" 0.05; then
          echo "not yet: rate_per_second is $ans, which is requests per minute. RED's rate is per second."
        else
          echo "not yet: rate_per_second is $ans. Count the customer-page requests between 10:15:00 and"
          echo "         10:29:59 and divide by the 900 seconds of the window."
        fi
        exit 1
      fi
      num error_percent
      if awk -v x="$ans" -v y="$ERR" 'BEGIN { d = x - y; exit !(d > 0.3 || d < -0.3) }'; then
        echo "not yet: error_percent is $ans. Errors in RED are the requests the service failed: 5xx,"
        echo "         as a share of all customer-page requests in the window."
        exit 1
      fi
      num p99_ms
      if ! near "$ans" "$P99" 0.1; then
        if near "$ans" "$MEAN" 0.15 || near "$ans" "$P50" 0.15; then
          echo "not yet: p99_ms is $ans: the middle of the window (its mean is $(printf %.0f "$MEAN") ms, its median"
          echo "         $P50 ms). The middle blends the fast home page with the slow checkout. p99 is the"
          echo "         slowest 1%, the experience the worst-served customers had."
        else
          echo "not yet: p99_ms is $ans. Sort the window's Ta values (the last of the five timers) and take"
          echo "         the one 99% of the way up."
        fi
        exit 1
      fi
      echo "RED, 10:15-10:30: $(printf %.2f "$RATE") req/s, $(printf %.2f "$ERR")% errors, p99 ${P99} ms"

      since=$(val customers_hurting_since | tr -d ' ')
      case $since in
        10:11|10:12|10:13) ;;
        *)
          echo "not yet: customers_hurting_since is '${since:-missing}'. Look at the duration of /cart and"
          echo "         /orders minute by minute from 10:00: the step is sharp."
          exit 1 ;;
      esac
      echo "customers hurting since $since"

      res=$(val saturated_resource | tr -d ' ')
      case $res in
        disk) ;;
        memory)
          echo "not yet: saturated_resource is memory. pg1's memory is 93% used and swap-in is 0: high"
          echo "         utilization with no saturation is the page cache doing its job. USE asks about"
          echo "         saturation, work waiting: which resource has a queue?"
          exit 1 ;;
        cpu|network)
          echo "not yet: saturated_resource is $res. Its utilization is low and nothing is queueing on it."
          exit 1 ;;
        *)
          echo "not yet: saturated_resource is '${res:-missing}'; one of cpu, memory, disk, network."
          exit 1 ;;
      esac
      echo "pg1 saturated on disk: under 100% busy, and a queue of over 10"

      got=$(val mismatched_claims | tr -c 'a-z\n' ' ' | tr ' ' '\n' | grep -E '^[a-d]$' | sort -u | tr -d '\n' || true)
      case $got in
        ad) ;;
        *)
          echo "not yet: mismatched_claims is '$(val mismatched_claims)'."
          case $got in *a*) ;; *)
            echo "         A answers 'are customers fine?' with web1's and web2's CPU and memory. That is"
            echo "         USE, a method for finding a saturated resource; it says nothing about whether"
            echo "         requests succeed quickly, which is RED's question." ;; esac
          case $got in *b*)
            echo "         B is RED at the edge answering 'are customers hurting, and since when?' That is"
            echo "         the question RED is for." ;; esac
          case $got in *c*)
            echo "         C is USE on pg1's disk: saturation, measured as a queue. That is the question"
            echo "         USE is for: which resource is the bottleneck." ;; esac
          case $got in *d*) ;; *)
            echo "         D answers 'is pg1 the bottleneck?' with its request rate and errors. That is RED,"
            echo "         which sees a service from outside: a database whose disk is queueing still"
            echo "         serves every query, slowly, and reports no errors." ;; esac
          exit 1 ;;
      esac
      echo
      echo "PASS — RED says customers hurt from $since; USE says pg1's disk is why; A and D used the other method."
---
