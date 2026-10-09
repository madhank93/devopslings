---
kind: lesson
title: "Synchronised retries from 200 clients"
description: |
  Two hundred dashboards long-poll a price feed. They retry with exponential
  backoff, capped attempts, no immediate hammering: everything the last lesson
  asked for. A one-second network blip drops every connection at once, and
  the feed spends the next twenty seconds being hit by the same two hundred
  clients in perfect unison.
name: backoff-and-jitter
slug: backoff-and-jitter
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
      RETRY_MAX_ATTEMPTS=6
      RETRY_BACKOFF_MS=500
      RETRY_JITTER=none
      ENV
      docker compose up -d --wait >/dev/null 2>&1 || true

      echo "scenario ready — 200 clients will long-poll the price feed on pricing:8140,"
      echo "retrying with exponential backoff from 500ms, up to 6 attempts, no jitter."
      echo
      echo "At verify time the network drops every connection at once and stays down"
      echo "for 1 second. Configure the retry policy in sandboxes/chaos-stack/.env."

  # Starts the feed fresh, so every verify begins with empty counters and an
  # enabled proxy no matter how the previous run ended.
  inject_fault:
    timeout_seconds: 120
    run: |
      feed=$(cat <<'PY'
      # The price feed: a long poll. Registering a subscriber is serialised work
      # (WORK seconds at one desk, so 1 / WORK per second); after that the
      # connection is held for HOLD seconds and answered.
      import json, sys, threading, time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import urlparse, parse_qs

      PORT, WORK, HOLD = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
      desk, lock = threading.Lock(), threading.Lock()
      arrivals, marks = [], {}

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
              if u.path == "/feed":
                  with lock:
                      arrivals.append(time.time())
                  with desk:
                      time.sleep(WORK)
                  time.sleep(HOLD)
                  self.reply(200, {"price": 42.0})
              elif u.path == "/stats":
                  with lock:
                      a = list(arrivals)
                  s, b = marks.get("start", 0), marks.get("blip", 0)
                  tenths = {}
                  for t in a:
                      if t >= b:
                          k = int((t - b) * 10)
                          tenths[k] = tenths.get(k, 0) + 1
                  steady = sum(1 for t in a if s + 5 <= t < b) / max((b - s - 5) * 10, 0.1)
                  peak = max(tenths.values(), default=0)
                  halves = [sum(tenths.get(i * 5 + j, 0) for j in range(5)) for i in range(30)]
                  self.reply(200, {"arrivals": len(a), "steady_per_100ms": round(steady, 1),
                                   "peak_per_100ms": peak,
                                   "peak_at_s": min((k for k, v in tenths.items() if v == peak), default=0) / 10,
                                   "per_500ms_after_blip": halves})
              else:
                  self.reply(404, {})
          def do_POST(self):
              u = urlparse(self.path)
              if u.path == "/reset":
                  with lock:
                      arrivals.clear(); marks.clear()
              elif u.path == "/mark":
                  marks[parse_qs(u.query)["name"][0]] = time.time()
              self.reply(200, {})

      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer.request_queue_size = 1024
      ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
      PY
      )

      docker compose exec -T pricing sh -c '
        p=$(cat /tmp/backoff-feed.pid 2>/dev/null) || exit 0
        kill "$p" 2>/dev/null || exit 0
        while kill -0 "$p" 2>/dev/null; do sleep 0.1; done' || true
      docker compose exec -d -T -e SRC="$feed" pricing \
        sh -c 'echo $$ > /tmp/backoff-feed.pid; exec python3 -c "$SRC" 8140 0.010 4'

      up=no
      for _ in $(seq 1 50); do
        if docker compose exec -T pricing python3 -c \
          "import urllib.request; urllib.request.urlopen('http://localhost:8140/stats', timeout=1)" \
          >/dev/null 2>&1; then up=yes; break; fi
        sleep 0.2
      done
      [ "$up" = yes ] || { echo "the feed did not start on pricing:8140"; exit 1; }

      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/backoff-feed >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
        -d '{"name":"backoff-feed","listen":"0.0.0.0:21140","upstream":"pricing:8140"}' >/dev/null

      echo "fault armed: 10s into the load test every feed connection drops, and the"
      echo "network stays down for 1s"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
      attempts=$(env_val RETRY_MAX_ATTEMPTS); base=$(env_val RETRY_BACKOFF_MS); jitter=$(env_val RETRY_JITTER)

      case "$jitter" in none|full|equal) ;; *)
        echo "not yet: RETRY_JITTER='${jitter}' is not one of none, full, equal."; exit 1 ;;
      esac
      if ! printf '%s' "$base" | grep -Eq '^[0-9]+$'; then
        echo "not yet: RETRY_BACKOFF_MS='${base}' is not a whole number of milliseconds."; exit 1
      fi
      # Unbounded attempts are invisible under a 1s fault, so this one is read
      # from config: a client that never gives up never reports the outage.
      if ! printf '%s' "$attempts" | grep -Eq '^[0-9]+$' || [ "$attempts" -lt 1 ] || [ "$attempts" -gt 10 ]; then
        echo "not yet: RETRY_MAX_ATTEMPTS='${attempts}' — attempts must be bounded (1 to 10)."
        echo "This fault lasts one second, so a client that retries forever looks fine here. In a"
        echo "ten-minute outage it never gives up, never tells its user, and is still in the herd"
        echo "when the feed comes back."
        exit 1
      fi

      # The thresholds are the grade. teardown() reads the feed's own arrival
      # log, so the herd is measured where it lands.
      rc=0
      out=$(docker compose exec -T k6 k6 run --quiet --log-output=none \
              -e RETRY_MAX_ATTEMPTS="$attempts" -e RETRY_BACKOFF_MS="$base" -e RETRY_JITTER="$jitter" \
              - 2>&1 <<'JS'
      import http from 'k6/http';
      import { sleep } from 'k6';
      import { Counter, Gauge, Trend } from 'k6/metrics';

      const FEED = 'http://pricing:8140';
      const ADMIN = 'http://toxiproxy:8474/proxies/backoff-feed';
      const ATTEMPTS = parseInt(__ENV.RETRY_MAX_ATTEMPTS);
      const BASE = parseInt(__ENV.RETRY_BACKOFF_MS);
      const JITTER = __ENV.RETRY_JITTER;
      const END_S = 30;

      const recovery = new Trend('recovery_ms', true);
      const gaveUp = new Counter('gave_up');
      const peakRatio = new Gauge('herd_peak_ratio');
      const peak = new Gauge('feed_peak_per_100ms');
      const peakAt = new Gauge('feed_peak_at_s');
      const steady = new Gauge('feed_steady_per_100ms');

      export const options = {
        scenarios: {
          clients: { executor: 'per-vu-iterations', vus: 200, iterations: 1, maxDuration: '60s', exec: 'client' },
          fault: { executor: 'per-vu-iterations', vus: 1, iterations: 1, startTime: '10s', exec: 'drop' },
        },
        thresholds: {
          gave_up: ['count<1'],                 // every dropped poll gets its answer
          recovery_ms: ['p(95)<10000'],         // drop -> answered, including the 4s hold
          herd_peak_ratio: ['value<15'],        // busiest 100ms after the drop / a normal 100ms
        },
      };

      export function setup() {
        http.post(`${FEED}/reset`);
        http.post(`${FEED}/mark?name=start`);
        return Date.now();
      }

      function delayS(n) {
        const d = BASE * Math.pow(2, n - 1);
        if (JITTER === 'full') return (Math.random() * d) / 1000;
        if (JITTER === 'equal') return (d / 2 + (Math.random() * d) / 2) / 1000;
        return d / 1000;
      }

      // One client: poll, and when a poll fails, retry it with the policy.
      export function client(start) {
        sleep(Math.random() * 4);
        while ((Date.now() - start) / 1000 < END_S) {
          let failedAt = 0;
          for (let n = 1; ; n++) {
            const r = http.get('http://toxiproxy:21140/feed', { timeout: '5s' });
            if (r.status === 200) {
              if (failedAt) recovery.add(Date.now() - failedAt);
              break;
            }
            if (!failedAt) failedAt = Date.now();
            if (n >= ATTEMPTS) { gaveUp.add(1); break; }
            sleep(delayS(n));
          }
          sleep(Math.random() * 0.5);
        }
      }

      // Disabling a toxiproxy proxy closes every connection through it.
      export function drop() {
        http.post(`${FEED}/mark?name=blip`);
        http.post(ADMIN, JSON.stringify({ enabled: false }));
        sleep(1);
        http.post(ADMIN, JSON.stringify({ enabled: true }));
      }

      export function teardown() {
        const s = http.get(`${FEED}/stats`).json();
        peak.add(s.peak_per_100ms);
        peakAt.add(s.peak_at_s);
        steady.add(s.steady_per_100ms);
        peakRatio.add(s.peak_per_100ms / Math.max(s.steady_per_100ms, 1));
      }

      export function handleSummary(d) {
        const v = (m, k) => (d.metrics[m] ? d.metrics[m].values[k] : -1);
        return { stdout: [
          `gave_up=${v('gave_up', 'count')}`,
          `recovery_p95=${v('recovery_ms', 'p(95)')}`,
          `peak=${v('feed_peak_per_100ms', 'value')}`,
          `peak_at=${v('feed_peak_at_s', 'value')}`,
          `steady=${v('feed_steady_per_100ms', 'value')}`,
          `ratio=${v('herd_peak_ratio', 'value')}`,
        ].join('\n') + '\n' };
      }
      JS
      ) || rc=$?

      val() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2 || true; }
      gave_up=$(val gave_up); p95=$(val recovery_p95); peak=$(val peak); peak_at=$(val peak_at)
      steady=$(val steady); ratio=$(val ratio)

      if [ -z "$gave_up" ] || [ -z "$ratio" ]; then
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test did not finish, so there is nothing to grade — output above."
        exit 1
      fi

      p95_s=$(awk -v p="$p95" 'BEGIN { printf "%.1f", p / 1000 }')
      echo "feed arrivals, per 500ms from the moment of the drop:"
      halves=$(docker compose exec -T pricing python3 -c "import json, urllib.request
      s = json.load(urllib.request.urlopen('http://localhost:8140/stats', timeout=5))
      print(' '.join(map(str, s['per_500ms_after_blip'])))" 2>/dev/null || true)
      echo "  ${halves:-unavailable}"
      echo "busiest 100ms: ${peak} arrivals, ${peak_at}s after the drop (a normal 100ms: ${steady})"
      echo "dropped polls answered within ${p95_s}s at p95; polls that gave up: ${gave_up}"
      echo

      if [ "$rc" -eq 0 ]; then
        echo "PASS — the clients came back spread out, and the feed absorbed them."
        exit 0
      fi

      if [ "$gave_up" != "0" ]; then
        echo "not yet: ${gave_up} polls gave up after RETRY_MAX_ATTEMPTS=${attempts} attempts. The network was"
        echo "down for one second; with RETRY_BACKOFF_MS=${base} and RETRY_JITTER=${jitter}, those retries"
        echo "all fired before it came back."
      elif awk -v r="$ratio" 'BEGIN { exit !(r >= 15) }'; then
        echo "not yet: the clients came back together — ${peak} arrivals in one 100ms window."
        echo "That was ${peak_at}s after the drop; a normal 100ms sees ${steady}."
        case "$jitter" in
          none)  echo "With RETRY_JITTER=none every client computes the same delay from the same moment," ;;
          equal) echo "With RETRY_JITTER=equal half of every delay is still identical across clients," ;;
          full)  echo "Even with full jitter, RETRY_BACKOFF_MS=${base} leaves too little room to spread into," ;;
        esac
        echo "so the retries land as one wave."
      else
        echo "not yet: the dropped polls took ${p95_s}s to be answered at p95; the budget is 10s,"
        echo "of which 4s is the feed's normal hold."
        case "$jitter" in
          none)  echo "With RETRY_JITTER=none the clients retry in step, and each wave waits on the one before." ;;
          equal) echo "With RETRY_JITTER=equal half of every delay is identical across clients, so the" ;;
          full)  echo "With RETRY_BACKOFF_MS=${base} the random delays themselves are long, so clients" ;;
        esac
        case "$jitter" in
          equal) echo "clients still come back in loose waves, and the stragglers queue behind them." ;;
          full)  echo "spend the time waiting rather than retrying." ;;
        esac
      fi
      exit 1
---
