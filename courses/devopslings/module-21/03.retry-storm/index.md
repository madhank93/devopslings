---
kind: lesson
title: "The retry that turns a blip into an outage"
description: |
  checkout retries pricing on every error, five times, immediately. It made a
  flaky network invisible to customers. Then the network stalls for five
  seconds, every one of those retries lands on pricing at once, and pricing
  never catches up — long after the network is fine again.
name: retry-storm
slug: retry-storm
createdAt: "2026-10-08"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      # .env is gitignored sandbox state that outlives `compose down -v`, so it
      # is rewritten here or a solved attempt would survive a reset.
      cat > .env <<'ENV'
      RETRY_MAX_ATTEMPTS=5
      RETRY_ON=connect,timeout,5xx,4xx
      RETRY_BUDGET=0
      ENV
      docker compose up -d --wait >/dev/null 2>&1 || true

      echo "scenario ready — checkout-retry on :8130 retries the metered pricing copy"
      echo "on any error, up to 5 attempts, immediately."
      echo
      echo "At verify time the network between them resets 5% of connections for the"
      echo "whole run, and stalls completely for 5 seconds in the middle of it."
      echo "Configure the retry policy in sandboxes/chaos-stack/.env — see the task."

  # Starts both lesson processes fresh from the current .env, so every verify
  # grades the policy as written and starts with empty counters. It owns all of
  # its preconditions: nothing the student can leave behind makes it fail.
  inject_fault:
    timeout_seconds: 120
    run: |
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }

      ledger=$(cat <<'PY'
      # pricing, metered: same answer as pricing, plus a server-side count of
      # every request that reaches it. One desk serialises the work, which is
      # what gives it a capacity (1 / WORK requests per second) to exceed.
      import json, sys, threading, time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse, parse_qs

      PORT, WORK = int(sys.argv[1]), float(sys.argv[2])
      desk, lock = threading.Lock(), threading.Lock()
      arrivals, answered, marks = [], {}, {}

      def rate(a, lo, hi):
          return sum(1 for t, _ in a if lo <= t < hi) / max(hi - lo, 0.001)

      class H(BaseHTTPRequestHandler):
          def log_message(self, *a): pass
          def reply(self, code, body):
              data = json.dumps(body).encode()
              self.send_response(code)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              try: self.wfile.write(data)
              except OSError: pass
          def do_GET(self):
              u = urlparse(self.path)
              if u.path == "/price":
                  rid = self.headers.get("X-Request-Id", "")
                  # A 404 sent during the stall reached checkout late, as a timeout, so
                  # a retry of it is a retried timeout; only a delivered 404 counts.
                  with lock:
                      code, sent = answered.get(rid, (0, 0))
                      b, c = marks.get("blip"), marks.get("clear")
                      late = b is not None and sent >= b and (c is None or sent < c + 2)
                      arrivals.append((time.time(), code == 404 and not late))
                  with desk:
                      time.sleep(WORK)
                  code = 404 if parse_qs(u.query).get("sku", [""])[0] == "retired" else 200
                  with lock:
                      answered[rid] = (code, time.time())
                  self.reply(code, {"price": 42.0} if code == 200 else {"error": "unknown sku"})
              elif u.path == "/stats":
                  with lock:
                      a = list(arrivals)
                  s, b, c = marks.get("start", 0), marks.get("blip", 0), marks.get("clear", 0)
                  self.reply(200, {"arrivals": len(a), "retried_404": sum(1 for _, r in a if r),
                                   "steady_rate": round(rate(a, s + 2, b), 1),
                                   "blip_rate": round(rate(a, b, c), 1),
                                   "after_rate": round(rate(a, c + 4, c + 15), 1)})
              else:
                  self.reply(404, {})
          def do_POST(self):
              u = urlparse(self.path)
              if u.path == "/reset":
                  with lock:
                      arrivals.clear(); answered.clear(); marks.clear()
              elif u.path == "/mark":
                  marks[parse_qs(u.query)["name"][0]] = time.time()
              self.reply(200, {})

      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer.request_queue_size = 1024
      ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
      PY
      )

      client=$(cat <<'PY'
      # checkout-retry: answers /checkout by calling pricing with the retry
      # policy from the environment. One process, so the budget is shared by
      # every request it serves, the way a real client library's would be.
      import json, os, sys, threading, uuid
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse, parse_qs
      import requests

      PORT, UPSTREAM = int(sys.argv[1]), sys.argv[2]
      MAX_ATTEMPTS = int(os.environ.get("RETRY_MAX_ATTEMPTS") or 1)
      RETRY_ON = {s.strip() for s in os.environ.get("RETRY_ON", "").split(",") if s.strip()}
      BUDGET = float(os.environ.get("RETRY_BUDGET") or 0)
      tokens, tlock = 0.0, threading.Lock()

      def earn():
          global tokens
          with tlock:
              tokens = min(10.0, tokens + BUDGET)

      def spend():
          global tokens
          if BUDGET <= 0:
              return True
          with tlock:
              if tokens >= 1:
                  tokens -= 1
                  return True
              return False

      def call(sku):
          rid, attempt = uuid.uuid4().hex, 0
          earn()
          while True:
              attempt += 1
              try:
                  r = requests.get(f"{UPSTREAM}/price", params={"sku": sku}, timeout=1.0,
                                   headers={"X-Request-Id": rid})
                  if r.status_code == 200:
                      return 200, r.json()
                  kind, result = f"{r.status_code // 100}xx", (r.status_code, {"error": r.status_code})
              except requests.Timeout:
                  kind, result = "timeout", (503, {"error": "timeout"})
              except requests.ConnectionError:
                  kind, result = "connect", (503, {"error": "connect"})
              if kind not in RETRY_ON or (MAX_ATTEMPTS > 0 and attempt >= MAX_ATTEMPTS) or not spend():
                  return result

      class H(BaseHTTPRequestHandler):
          def log_message(self, *a): pass
          def do_GET(self):
              u = urlparse(self.path)
              code, body = (200, {"status": "ok"}) if u.path == "/health" else \
                  call(parse_qs(u.query).get("sku", ["widget"])[0])
              data = json.dumps(body).encode()
              self.send_response(code)
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              try: self.wfile.write(data)
              except OSError: pass

      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer.request_queue_size = 1024
      ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
      PY
      )

      # Stop any previous copy and wait for it to release the port.
      stop() {
        docker compose exec -T "$1" sh -c '
          p=$(cat /tmp/'"$2"'.pid 2>/dev/null) || exit 0
          kill "$p" 2>/dev/null || exit 0
          while kill -0 "$p" 2>/dev/null; do sleep 0.1; done' || true
      }
      ready() {
        for _ in $(seq 1 50); do
          docker compose exec -T "$1" python3 -c \
            "import urllib.request; urllib.request.urlopen('$2', timeout=1)" >/dev/null 2>&1 && return 0
          sleep 0.2
        done
        echo "$1 did not answer on $2"; return 1
      }

      stop pricing retry-storm-ledger
      stop checkout retry-storm-client
      docker compose exec -d -T -e SRC="$ledger" pricing \
        sh -c 'echo $$ > /tmp/retry-storm-ledger.pid; exec python3 -c "$SRC" 8130 0.020'
      docker compose exec -d -T -e SRC="$client" \
        -e RETRY_MAX_ATTEMPTS="$(env_val RETRY_MAX_ATTEMPTS)" \
        -e RETRY_ON="$(env_val RETRY_ON)" \
        -e RETRY_BUDGET="$(env_val RETRY_BUDGET)" checkout \
        sh -c 'echo $$ > /tmp/retry-storm-client.pid; exec python3 -c "$SRC" 8130 http://toxiproxy:21130'
      ready pricing http://localhost:8130/stats
      ready checkout http://localhost:8130/health

      # Upstream-direction resets drop the request before pricing sees it, so a
      # retried reset never looks like a retried 404 in pricing's counters.
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/retry-storm >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
        -d '{"name":"retry-storm","listen":"0.0.0.0:21130","upstream":"pricing:8130"}' >/dev/null
      curl -fsS -X POST http://127.0.0.1:8474/proxies/retry-storm/toxics -H 'Content-Type: application/json' \
        -d '{"name":"flaky","type":"reset_peer","stream":"upstream","toxicity":0.05,"attributes":{"timeout":0}}' \
        >/dev/null

      echo "fault armed: 5% of connections reset; a 5s stall fires 10s into the load test"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
      attempts=$(env_val RETRY_MAX_ATTEMPTS); retry_on=$(env_val RETRY_ON); budget=$(env_val RETRY_BUDGET)

      # The thresholds are the grade. teardown() reads pricing's own counters, so
      # what the dependency received is graded, not what checkout reports.
      rc=0
      out=$(docker compose exec -T k6 k6 run --quiet --log-output=none - 2>&1 <<'JS'
      import http from 'k6/http';
      import { check, sleep } from 'k6';
      import exec from 'k6/execution';
      import { Counter, Gauge } from 'k6/metrics';

      const LEDGER = 'http://pricing:8130';
      const ADMIN = 'http://toxiproxy:8474/proxies/retry-storm';
      const retried404 = new Counter('retried_404');
      const amplification = new Gauge('upstream_amplification');
      const steadyRate = new Gauge('pricing_steady_rps');
      const blipRate = new Gauge('pricing_blip_rps');
      const afterRate = new Gauge('pricing_after_rps');

      export const options = {
        scenarios: {
          // Open-loop: customers keep arriving whether or not pricing is coping.
          users: { executor: 'constant-arrival-rate', rate: 25, timeUnit: '1s', duration: '30s',
                   preAllocatedVUs: 50, maxVUs: 400, exec: 'users' },
          fault: { executor: 'per-vu-iterations', vus: 1, iterations: 1, startTime: '10s', exec: 'stall' },
        },
        thresholds: {
          'checks{phase:steady}': ['rate>0.99'],
          'checks{phase:after}': ['rate>0.95'],
          retried_404: ['count<1'],
          upstream_amplification: ['value<1.5'],
        },
      };

      export function setup() {
        http.post(`${LEDGER}/reset`);
        http.post(`${LEDGER}/mark?name=start`);
      }

      export function users() {
        const t = (Date.now() - exec.scenario.startTime) / 1000;
        const phase = t < 10 ? 'steady' : t < 15 ? 'stall' : t < 19 ? 'recovering' : 'after';
        const sku = Math.random() < 0.1 ? 'retired' : 'widget';
        const r = http.get(`http://checkout:8130/checkout?sku=${sku}`, { timeout: '30s', tags: { phase } });
        check(r, { 'correct answer': (r) => r.status === (sku === 'retired' ? 404 : 200) }, { phase });
      }

      export function stall() {
        http.post(`${LEDGER}/mark?name=blip`);
        http.post(`${ADMIN}/toxics`, JSON.stringify({ name: 'stall', type: 'latency', stream: 'downstream',
                                                       attributes: { latency: 1500 } }));
        sleep(5);
        http.del(`${ADMIN}/toxics/stall`);
        http.post(`${LEDGER}/mark?name=clear`);
      }

      export function teardown() {
        const s = http.get(`${LEDGER}/stats`).json();
        retried404.add(s.retried_404);
        amplification.add(s.blip_rate / Math.max(s.steady_rate, 1));
        steadyRate.add(s.steady_rate);
        blipRate.add(s.blip_rate);
        afterRate.add(s.after_rate);
      }

      export function handleSummary(d) {
        const v = (m, k) => (d.metrics[m] ? d.metrics[m].values[k] : -1);
        return { stdout: [
          `steady=${v('checks{phase:steady}', 'rate')}`,
          `after=${v('checks{phase:after}', 'rate')}`,
          `retried_404=${v('retried_404', 'count')}`,
          `amplification=${v('upstream_amplification', 'value')}`,
          `steady_rps=${v('pricing_steady_rps', 'value')}`,
          `blip_rps=${v('pricing_blip_rps', 'value')}`,
          `after_rps=${v('pricing_after_rps', 'value')}`,
        ].join('\n') + '\n' };
      }
      JS
      ) || rc=$?

      val() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2 || true; }
      pct() { awk -v r="$1" 'BEGIN { printf "%.1f%%", r * 100 }'; }
      steady=$(val steady); after=$(val after); r404=$(val retried_404); amp=$(val amplification)
      s_rps=$(val steady_rps); b_rps=$(val blip_rps); a_rps=$(val after_rps)

      echo "customers served correctly — before the stall: $(pct "${steady:-0}"), after it: $(pct "${after:-0}")"
      echo "pricing received — steady: ${s_rps:-?}/s, during the stall: ${b_rps:-?}/s, after: ${a_rps:-?}/s (capacity 50/s)"
      echo

      if [ -z "$steady" ]; then
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test did not finish, so there is nothing to grade — output above."
        exit 1
      fi

      if [ "$rc" -eq 0 ]; then
        echo "PASS — the stall cost the customers who were in it, and only them."
        exit 0
      fi

      if awk -v n="$r404" 'BEGIN { exit !(n > 0) }'; then
        echo "not yet: pricing answered 404 for an unknown SKU and then received the same"
        echo "request again ${r404} times. A 404 is an answer, not a failure — it will be a 404 on"
        if printf '%s' ",$retry_on," | grep -q ',4xx,'; then
          echo "every attempt. RETRY_ON='${retry_on}' includes 4xx."
        else
          echo "every attempt. RETRY_ON='${retry_on}' — check what else in it a 404 could match."
        fi
      elif awk -v r="$steady" 'BEGIN { exit !(r <= 0.99) }'; then
        if [ "${attempts:-1}" = 1 ]; then
          why="RETRY_MAX_ATTEMPTS='${attempts}' means one attempt and no retry"
        elif ! printf '%s' ",$retry_on," | grep -q ',connect,'; then
          why="RETRY_ON='${retry_on}' does not include connect, which is what a reset is"
        else
          why="with RETRY_BUDGET='${budget}' too few retries were allowed to cover them"
        fi
        echo "not yet: with nothing stalled, only $(pct "$steady") of customers got the right answer."
        echo "5% of connections are reset and a single retry fixes each one, but $why."
      elif awk -v a="$amp" 'BEGIN { exit !(a >= 1.5) }'; then
        echo "not yet: retries multiplied pricing's load during the stall — ${s_rps}/s became ${b_rps}/s."
        if awk -v b="$budget" 'BEGIN { exit !(b + 0 <= 0) }'; then
          echo "RETRY_MAX_ATTEMPTS=${attempts} caps each request, not the total: when every request fails, every"
          echo "request uses all of its attempts. Nothing limits retries as a share of traffic (RETRY_BUDGET=${budget})."
        else
          echo "RETRY_BUDGET=${budget} still let retries push pricing to 1.5x its normal load or more."
        fi
        if awk -v r="$after" 'BEGIN { exit !(r <= 0.95) }'; then
          echo "And it never recovered: after the network was fine, only $(pct "$after") of customers were served."
        fi
      elif awk -v r="$after" 'BEGIN { exit !(r <= 0.95) }'; then
        echo "not yet: the stall ended and customers still were not served — $(pct "$after") after it, with"
        echo "pricing receiving ${a_rps}/s."
      else
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test failed a threshold not covered above — output above."
      fi
      exit 1
---
