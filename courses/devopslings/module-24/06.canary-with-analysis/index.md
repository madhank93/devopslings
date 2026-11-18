---
kind: lesson
title: "Canary with automated analysis"
description: |
  Build v2 of checkout passed CI and is running on web2. It is slower, and
  nothing caught it. Make web2 a real canary — a tenth of the traffic — and
  write the analysis that promotes a good build and rejects a bad one,
  naming the metric that moved.
name: canary-with-analysis
slug: canary-with-analysis
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
      mkdir -p /var/lib/devopslings/canary /ha/sre /ha/app/routes /ha/deploy/builds
      cat > /ha/app/routes/checkout.py <<'PY'
      # GET /checkout serves the build named in /ha/deploy/<this node>, from
      # /ha/deploy/builds/<build>.py, and says which in an X-Build header.
      import importlib.util
      import socket

      NODE = socket.gethostname()
      _builds = {}


      def handle(db):
          build = open(f"/ha/deploy/{NODE}").read().strip()
          if build not in _builds:
              spec = importlib.util.spec_from_file_location(build, f"/ha/deploy/builds/{build}.py")
              mod = importlib.util.module_from_spec(spec)
              spec.loader.exec_module(mod)
              _builds[build] = mod
          code, body, *rest = _builds[build].handle(db)
          return code, body, {**(rest[0] if rest else {}), "X-Build": build}
      PY
      # The builds: v1 is what runs today. The grader's candidates are written
      # beside them under names that say nothing about what they do.
      cat > /var/lib/devopslings/canary/good.py <<'PY'
      import random, time
      def handle(db):
          time.sleep(random.lognormvariate(-4.0, 0.4))
          if random.random() < 0.01:
              return 500, "checkout failed: payment provider timeout"
          return 200, "checkout ok"
      PY
      cat > /var/lib/devopslings/canary/slow.py <<'PY'
      import random, time
      def handle(db):
          time.sleep(random.uniform(0.4, 0.9) if random.random() < 0.25 else random.lognormvariate(-4.0, 0.4))
          if random.random() < 0.01:
              return 500, "checkout failed: payment provider timeout"
          return 200, "checkout ok"
      PY
      cat > /var/lib/devopslings/canary/errors.py <<'PY'
      import random, time
      def handle(db):
          time.sleep(random.lognormvariate(-4.0, 0.4))
          if random.random() < 0.06:
              return 500, "checkout failed: KeyError 'currency'"
          return 200, "checkout ok"
      PY
      cat > /var/lib/devopslings/canary/drive-traffic <<'PY'
      #!/usr/bin/env python3
      """drive-traffic SECONDS — customers on GET http://www/checkout, logged as lb1 would.

      Prints one HAProxy httplog line per request on stdout: the server that
      answered, the status and the total time in milliseconds.
      """
      import random
      import sys
      import threading
      import time
      import urllib.error
      import urllib.request
      from datetime import datetime

      end = time.time() + float(sys.argv[1])
      lock = threading.Lock()


      def worker():
          while time.time() < end:
              start = time.time()
              try:
                  with urllib.request.urlopen("http://www/checkout", timeout=5) as r:
                      status, server = r.status, r.headers.get("X-Served-By", "-")
                      r.read()
              except urllib.error.HTTPError as e:
                  status, server = e.code, e.headers.get("X-Served-By", "<NOSRV>")
              except Exception:
                  status, server = 503, "<NOSRV>"
              ta = int((time.time() - start) * 1000)
              ts = datetime.fromtimestamp(start)
              with lock:
                  print(f"198.51.100.{random.randint(2, 254)}:{random.randint(32768, 60999)} "
                        f"[{ts:%d/%b/%Y:%H:%M:%S}.{ts.microsecond // 1000:03d}] www app/{server} "
                        f"0/0/1/{max(0, ta - 1)}/{ta} {status} 64 - - ---- 8/8/0/0/0 0/0 "
                        f'"GET /checkout HTTP/1.1"', flush=True)


      threads = [threading.Thread(target=worker) for _ in range(8)]
      for t in threads:
          t.start()
      for t in threads:
          t.join()
      PY
      chmod +x /var/lib/devopslings/canary/drive-traffic
      cp /var/lib/devopslings/canary/drive-traffic /ha/sre/drive-traffic
      cp /var/lib/devopslings/canary/good.py /ha/deploy/builds/v1.py
      cp /var/lib/devopslings/canary/slow.py /ha/deploy/builds/v2.py
      echo v1 > /ha/deploy/web1
      echo v2 > /ha/deploy/web2
      cat > /ha/sre/ci-smoke <<'SH'
      #!/bin/bash
      # CI's smoke test for checkout: five requests to the node, all must be 200.
      node=${1:?usage: ci-smoke <web1|web2>}
      for i in 1 2 3 4 5; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$node:8080/checkout")
        [ "$code" = 200 ] || { echo "FAIL: request $i answered $code"; exit 1; }
      done
      echo "PASS: 5/5"
      SH
      chmod +x /ha/sre/ci-smoke
      rm -f /ha/sre/canary-analysis
      for _ in $(seq 20); do curl -fsS --max-time 2 http://www/checkout >/dev/null 2>&1 && break; sleep 0.5; done
      echo "scenario ready — web1 runs checkout v1, web2 runs v2, and v2 passed CI:"
      /ha/sre/ci-smoke web2 || true
      echo
      echo "  the builds:             /ha/deploy/builds/   (which node runs which: /ha/deploy/web1, web2)"
      echo "  real traffic, logged:   /ha/sre/drive-traffic 15 > /ha/sre/sample.log"
      echo "  the load balancer:      /ha/haproxy.cfg"
      echo "  your analysis:          /ha/sre/canary-analysis <log>   (exit 0 promote, exit 1 reject)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      d=/var/lib/devopslings/canary
      if [ ! -x "$d/drive-traffic" ]; then
        echo "not yet: the scenario's builds are missing. Reset the lesson."
        exit 1
      fi
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"; rm -f /ha/deploy/builds/c-*.py; echo v1 > /ha/deploy/web2' EXIT

      # Each candidate is deployed to web2 under a fresh name, driven with real
      # traffic, and the log handed to the analysis.
      round() {  # round <good|slow|errors> — sets log, rc, verdict
        local name="c-$RANDOM$RANDOM"
        cp "$d/$1.py" "/ha/deploy/builds/$name.py"
        echo "$name" > /ha/deploy/web2
        sleep 1
        log="$tmp/$1.log"
        "$d/drive-traffic" 15 > "$log"
        rc=0
        timeout 60 /ha/sre/canary-analysis "$log" > "$tmp/out" 2>&1 || rc=$?
        verdict=$(grep -Eio '^reject:[[:space:]]*[a-z]+' "$tmp/out" | tail -1 | sed 's/.*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' || true)
      }
      share() { awk '{ n++; if ($4 == "app/web2") c++ } END { printf "%.3f", n ? c / n : 0 }' "$1"; }
      rate() { awk -v s="$2" '$4 == "app/" s { n++; if ($6 >= 500) e++ } END { printf "%.1f", n ? 100 * e / n : 0 }' "$1"; }
      p95() { awk -v s="$2" '$4 == "app/" s { split($5, t, "/"); print t[5] }' "$1" | sort -n | awk '{ a[NR] = $1 } END { print NR ? a[int(NR * 0.95)] : 0 }'; }
      show() { if [ -s "$tmp/out" ]; then tail -n 4 "$tmp/out" | sed 's/^/         | /'; else echo "         | (nothing)"; fi; }

      if [ ! -x /ha/sre/canary-analysis ]; then
        echo "not yet: /ha/sre/canary-analysis is missing or not executable."
        exit 1
      fi

      round good
      s=$(share "$log")
      if awk -v s="$s" 'BEGIN { exit !(s < 0.04 || s > 0.2) }'; then
        echo "not yet: web2 answered $(awk -v s="$s" 'BEGIN { printf "%.0f", s * 100 }')% of $(wc -l < "$log") requests through www. A canary takes about a tenth"
        echo "         of the traffic, so a bad build hurts a few customers instead of half of them."
        echo "         Its share is set by the servers' weights in /ha/haproxy.cfg."
        exit 1
      fi
      echo "web2 is a canary: $(awk -v s="$s" 'BEGIN { printf "%.0f", s * 100 }')% of the traffic"
      if [ "$rc" != 0 ]; then
        echo "not yet: the analysis rejected a good build (exit $rc). Its output:"
        show
        echo "         On this run the canary's error rate was $(rate "$log" web2)% against the baseline's $(rate "$log" web1)%,"
        echo "         and its p95 $(p95 "$log" web2) ms against $(p95 "$log" web1) ms. v1 fails a few checkouts too: the"
        echo "         question is whether the canary is worse than the baseline, not whether it is perfect."
        exit 1
      fi
      echo "a good build: promoted"

      round errors
      if [ "$rc" = 0 ]; then
        echo "not yet: the analysis promoted a build that fails $(rate "$log" web2)% of checkouts; the baseline fails"
        echo "         $(rate "$log" web1)%. Its output:"
        show
        echo "         With a tenth of the traffic, the canary's count of errors can be smaller than the"
        echo "         baseline's even when its rate is ten times higher. Compare rates."
        exit 1
      fi
      if [ "$verdict" != errors ]; then
        echo "not yet: the analysis rejected the build, and named '${verdict:-nothing}' (it needs a line 'reject: errors')."
        echo "         The metric that moved is the error rate: $(rate "$log" web2)% against $(rate "$log" web1)%, with latency"
        echo "         unchanged. Whoever reads the rejection goes looking where it points."
        exit 1
      fi
      echo "a build failing $(rate "$log" web2)% of checkouts: rejected on errors"

      round slow
      if [ "$rc" = 0 ]; then
        echo "not yet: the analysis promoted a build whose p95 is $(p95 "$log" web2) ms against the baseline's"
        echo "         $(p95 "$log" web1) ms, and an error rate no worse ($(rate "$log" web2)% against $(rate "$log" web1)%). Its output:"
        show
        echo "         An analysis that only reads status codes cannot see a slow build; this is the one"
        echo "         that passed CI."
        exit 1
      fi
      if [ "$verdict" != latency ]; then
        echo "not yet: the analysis rejected the build, and named '${verdict:-nothing}' (it needs a line 'reject: latency')."
        echo "         Its error rate was $(rate "$log" web2)%, the baseline's $(rate "$log" web1)%: what moved is latency,"
        echo "         p95 $(p95 "$log" web2) ms against $(p95 "$log" web1) ms."
        exit 1
      fi
      echo "a build with p95 $(p95 "$log" web2) ms: rejected on latency"
      echo
      echo "PASS — the canary gets a tenth of the traffic, and the analysis rejects on the metric that moved."
---
