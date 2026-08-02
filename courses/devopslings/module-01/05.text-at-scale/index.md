---
kind: lesson
title: "three numbers out of 390,000 lines, before standup"
description: |
  An access log nobody has an index for, and three questions that have exact
  answers. `grep -c 503` is wrong, and the reason it is wrong is the lesson.
  Graded on the answers, so a slow pipeline that is right beats a clever one
  that is not.
name: text-at-scale
slug: text-at-scale
createdAt: "2026-08-02"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/logs /var/lib/devopslings /root/answers

      # The log is generated rather than shipped: 64 MB of realistic noise in a
      # repo is a bad trade, and a seeded generator gives every student the
      # same answers without anyone having to store them.
      python3 - <<'PY'
      import random

      random.seed(20260802)

      customers = [f"cust-{i:05d}" for i in range(1, 61)]
      NOISY = "cust-00042"   # the one that actually breaks

      # Paths and sizes carry "503" and "502" on purpose. Every naive
      # `grep -c 503` in the world counts these.
      paths = [
          "/api/v1/orders", "/api/v1/orders?page=2", "/api/v1/orders/503",
          "/api/v1/customers", "/api/v1/customers?ref=502", "/api/v1/cart",
          "/static/js/app.503.min.js", "/static/css/main.css",
          "/healthz", "/api/v1/checkout", "/api/v1/search?q=503+error",
      ]
      sizes = [231, 503, 1204, 5031, 88, 15022, 503, 742, 20481]
      agents = [
          "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126.0 Safari/537.36",
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) Version/17.5 Safari/605.1.15",
          "curl/8.5.0",
          "checkout-worker/2.3 (+https://example.internal/checkout)",
      ]
      ok_statuses = [200, 200, 200, 200, 201, 204, 301, 304, 404]
      bad_statuses = [500, 502, 503, 504]

      # 09:14 is the busiest minute by a wide margin — wide enough that nobody
      # has to worry about a tie.
      SPIKE_H, SPIKE_M = 9, 14

      out = open("/srv/logs/access.log", "w")
      for minute in range(1440):
          h, m = divmod(minute, 60)
          n = random.randint(240, 300)
          if (h, m) == (SPIKE_H, SPIKE_M):
              n += 900
          rows = []
          for _ in range(n):
              cust = random.choice(customers)
              # The noisy customer fails far more often than anyone else, so
              # "who is generating the 5xx" has one obvious answer.
              bad = random.random() < (0.25 if cust == NOISY else 0.018)
              status = random.choice(bad_statuses if bad else ok_statuses)
              rows.append((
                  random.randint(0, 59),
                  f"198.51.100.{random.randint(1, 254)}",
                  cust,
                  random.choice(["GET", "GET", "GET", "POST", "PUT"]),
                  random.choice(paths),
                  status,
                  random.choice(sizes),
                  round(random.uniform(0.004, 2.5), 3),
                  random.choice(agents),
              ))
          rows.sort(key=lambda r: r[0])
          for s, ip, cust, meth, path, status, size, lat, ua in rows:
              out.write(
                  f'{ip} - {cust} [02/Aug/2026:{h:02d}:{m:02d}:{s:02d} +0000] '
                  f'"{meth} {path} HTTP/1.1" {status} {size} {lat:.3f} "{ua}"\n'
              )
      out.close()
      PY

      # A fingerprint of the log as generated. The check compares against it —
      # not to catch cheating so much as to catch `sort file > file`, which
      # truncates the input before sort ever reads it and is the single most
      # expensive mistake in this lesson.
      sha256sum /srv/logs/access.log | awk '{print $1}' > /var/lib/devopslings/text-at-scale.sha256

      cat > /root/questions.txt <<'Q'
      Answer each question by writing the answer, and nothing else, to a file:

        /root/answers/q1   how many requests got a 5xx status?
                           (a plain integer)

        /root/answers/q2   which customer generated the most 5xx responses?
                           (the customer id, e.g. cust-00007)

        /root/answers/q3   which single minute of the day served the most
                           requests, counting every status?
                           (HH:MM, e.g. 14:37)

      The log is /srv/logs/access.log. Do not modify it.
      Q

      lines=$(wc -l < /srv/logs/access.log)
      echo "scenario ready — /srv/logs/access.log has $lines lines ($(du -h /srv/logs/access.log | cut -f1))"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      log=/srv/logs/access.log

      if [ ! -f "$log" ]; then
        echo "not yet: $log is gone — reset the lesson to get it back"
        exit 1
      fi
      want=$(cat /var/lib/devopslings/text-at-scale.sha256)
      got=$(sha256sum "$log" | awk '{print $1}')
      if [ "$want" != "$got" ]; then
        echo "not yet: $log is not the log the questions were asked about — it has been modified or truncated"
        echo "if you ran something like 'sort $log > $log', the shell emptied the file before sort read it. Reset the lesson."
        exit 1
      fi

      # Ground truth, recomputed every run: nothing on the box holds the
      # answers, so there is nothing to find by grepping the filesystem.
      #
      # Status is field 9 because the quoted request is exactly three fields
      # ("GET, /path, HTTP/1.1"). Anchoring on ^5[0-9][0-9]$ is what separates
      # a status from a byte count or a path that happens to contain 503.
      t1=$(awk '$9 ~ /^5[0-9][0-9]$/ {n++} END {print n+0}' "$log")
      t2=$(awk '$9 ~ /^5[0-9][0-9]$/ {c[$3]++} END {for (k in c) if (c[k] > best) {best = c[k]; who = k} print who}' "$log")
      # $4 is "[02/Aug/2026:09:14:33"; characters 14-18 are HH:MM.
      t3=$(awk '{c[substr($4, 14, 5)]++} END {for (k in c) if (c[k] > best) {best = c[k]; when = k} print when}' "$log")

      check() {
        q=$1; want=$2; label=$3
        f=/root/answers/$q
        if [ ! -s "$f" ]; then
          echo "not yet: /root/answers/$q is missing or empty — $label"
          exit 1
        fi
        got=$(tr -d '[:space:]' < "$f")
        if [ "$got" != "$want" ]; then
          echo "not yet: /root/answers/$q says '$got', which is not the answer — $label"
          exit 1
        fi
      }

      check q1 "$t1" "how many requests got a 5xx status"
      check q2 "$t2" "which customer generated the most 5xx responses"
      check q3 "$t3" "which minute served the most requests"

      echo "PASS — $t1 5xx responses, mostly from $t2, and the busiest minute was $t3."
---
