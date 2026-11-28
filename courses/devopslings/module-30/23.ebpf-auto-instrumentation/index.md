---
kind: lesson
title: "RED metrics for a service nobody will instrument"
description: |
  A legacy service has no tracing SDK and nobody willing to add one. Beyla
  attaches eBPF programs to the running process and produces RED metrics and
  server spans from the kernel, with no code change. It is deployed next to
  ledger-legacy, and ledger-legacy is still missing from Prometheus and Tempo.
  Make every request it serves show up in both.
name: ebpf-auto-instrumentation
slug: ebpf-auto-instrumentation
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      mkdir -p /obs/beyla
      cat > /obs/beyla/beyla.yaml <<'YAML'
      # Beyla for ledger-legacy: RED metrics on :9400 for Prometheus, server
      # spans to Tempo. Started from the payments gateway's config.
      discovery:
        instrument:
          - open_ports: 8080
            name: ledger-legacy

      otel_traces_export:
        endpoint: http://tempo:4318
        sampler:
          name: traceidratio
          arg: "0.05"

      prometheus_export:
        port: 9400
      YAML
      chmod -R a+rwX /obs/beyla
      cat >> /obs/prometheus/prometheus.yml <<'YAML'

        - job_name: beyla
          static_configs:
            - targets: ["beyla:9400"]
      YAML
      obs_reload >/dev/null
      app_up ledger-legacy
      app_up beyla

      for _ in $(seq 1 60); do curl -fs -m 2 http://ledger-legacy:9480/entries/1 >/dev/null 2>&1 && break; sleep 1; done
      if ! curl -fs -m 2 http://ledger-legacy:9480/entries/1 >/dev/null 2>&1; then
        echo "scenario setup failed: ledger-legacy does not answer on :9480" >&2
        tail -5 /obs/logs/ledger-legacy.log >&2 || true
        exit 1
      fi
      for _ in $(seq 1 90); do curl -fs -m 2 http://beyla:9400/metrics >/dev/null 2>&1 && break; sleep 1; done
      if ! curl -fs -m 2 http://beyla:9400/metrics >/dev/null 2>&1; then
        echo "scenario setup failed: Beyla's metrics endpoint beyla:9400 never answered" >&2
        tail -5 /obs/logs/beyla.log >&2 || true
        exit 1
      fi

      echo "scenario ready — ledger-legacy serves GET /entries/<id> on http://ledger-legacy:9480."
      echo "Beyla runs beside it on /obs/beyla/beyla.yaml (restarts on save; log /obs/logs/beyla.log),"
      echo "and Prometheus scrapes it as job=\"beyla\". ledger-legacy is in neither Prometheus nor Tempo."

  verify_done:
    timeout_seconds: 300
    run: |
      python3 - <<'PY'
      import hashlib, http.client, json, re, sys, time, urllib.parse, urllib.request, uuid

      N = 20

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      def get(url, timeout=10):
          try:
              return urllib.request.urlopen(url, timeout=timeout).read().decode()
          except (OSError, http.client.HTTPException):
              return None

      def digest(p):
          try:
              return hashlib.sha256(open(p, "rb").read()).hexdigest()
          except OSError:
              return None
      if digest("/obs/apps/ledger_legacy.py") != digest("/opt/obs-baseline/apps/ledger_legacy.py"):
          no("/obs/apps/ledger_legacy.py is not the original. The point is RED metrics and spans with",
             "no change to the service: put it back with",
             "cp /opt/obs-baseline/apps/ledger_legacy.py /obs/apps/ and instrument it from outside.")

      def log_tail(n=3):
          try:
              lines = [l.rstrip() for l in open("/obs/logs/beyla.log") if "level=ERROR" in l or "[supervise]" in l]
          except OSError:
              return ["(no /obs/logs/beyla.log)"]
          return [l[:220] for l in lines[-n:]] or ["(no errors logged)"]

      def counts():
          """Beyla's own server request counters, summed per service_name."""
          text = get("http://beyla:9400/metrics")
          if text is None:
              return None
          out = {}
          for m in re.finditer(r'^http_server_request_duration_seconds_count\{([^}]*)\} (\S+)$', text, re.M):
              svc = re.search(r'service_name="([^"]*)"', m.group(1))
              key = svc.group(1) if svc else ""
              out[key] = out.get(key, 0) + float(m.group(2))
          return out

      def drive(prefix, n):
          for i in range(n):
              get(f"http://ledger-legacy:9480/entries/{prefix}-{i}")

      # Beyla takes several seconds after a start to find the process and attach.
      deadline = time.time() + 90
      c = None
      while time.time() < deadline:
          drive("warmup", 1)
          c = counts()
          if c and c.get("ledger-legacy"):
              break
          time.sleep(2)
      if c is None:
          no("Beyla's metrics endpoint beyla:9400 does not answer, so Beyla is not running on",
             "/obs/beyla/beyla.yaml. The errors in /obs/logs/beyla.log:", *log_tail())
      if not c.get("ledger-legacy"):
          others = sorted(k for k, v in c.items() if v)
          if others:
              no(f"Beyla counts ledger-legacy's requests under service_name={others[0]!r}, not",
                 "\"ledger-legacy\". Without a name, Beyla names a service after the program it runs, and",
                 "every dashboard and alert looks for ledger-legacy.")
          no("Beyla has counted no request to ledger-legacy after 90 s of traffic. It is running, so it",
             "has attached to nothing: no process it can see matches its discovery section.",
             "Find what ledger-legacy actually listens on, and compare.")

      # Beyla exports a request a moment after serving it: wait out the warmup's
      # stragglers so the baseline holds still.
      before = None
      for _ in range(10):
          time.sleep(3)
          now = (counts() or {}).get("ledger-legacy", 0)
          if now == before:
              break
          before = now
      run = uuid.uuid4().hex[:10]
      drive(f"verify-{run}", N)
      end = time.time() + 20
      while True:
          got = (counts() or {}).get("ledger-legacy", 0) - before
          if got >= N or time.time() > end:
              break
          time.sleep(1)
      if got != N:
          no(f"this check sent ledger-legacy {N} requests and Beyla counted {got:g}.")

      def promq(q):
          body = get("http://prometheus:9090/api/v1/query?" + urllib.parse.urlencode({"query": q}))
          try:
              r = json.loads(body)["data"]["result"]
              return float(r[0]["value"][1]) if r else None
          except (TypeError, ValueError, KeyError, IndexError):
              return None
      q = 'sum(http_server_request_duration_seconds_count{service_name="ledger-legacy"})'
      end = time.time() + 30
      while True:
          v = promq(q)
          if (v is not None and v >= before + N) or time.time() > end:
              break
          time.sleep(2)
      if v is None or v < before + N:
          no("Beyla counts ledger-legacy's requests, but Prometheus does not have them:",
             f"{q} is {v}. Prometheus scrapes Beyla as job=\"beyla\" on beyla:9400.")

      def traces():
          url = "http://tempo:3200/api/search?" + urllib.parse.urlencode({
              "q": f'{{resource.service.name="ledger-legacy" && span.url.path=~"/entries/verify-{run}-.*"}}',
              "start": int(time.time()) - 600, "end": int(time.time()) + 1, "limit": 200, "spss": 1})
          try:
              return len(json.loads(get(url, 15)).get("traces") or [])
          except (TypeError, ValueError, AttributeError):
              return 0
      # Tempo makes a trace searchable once it has been idle for a few seconds.
      end = time.time() + 45
      while True:
          t = traces()
          if t >= N or time.time() > end:
              break
          time.sleep(3)
      try:
          import yaml
          sampler = ((yaml.safe_load(open("/obs/beyla/beyla.yaml")) or {})
                     .get("otel_traces_export") or {}).get("sampler") or {}
          name = str(sampler.get("name", ""))
          sampling = "off" in name or ("ratio" in name and float(sampler.get("arg", 1)) < 1)
      except (OSError, ValueError, AttributeError, yaml.YAMLError):
          sampling = False
      # A 5% sampler leaves zero of 20 spans about a third of the time; that is sampling, not delivery.
      if t == 0 and not sampling:
          no(f"Tempo has no span for any of the {N} requests this check sent, though Beyla counted all",
             "of them, so Beyla is not delivering traces to Tempo. The errors in /obs/logs/beyla.log:",
             *log_tail())
      if t < N:
          no(f"Tempo has spans for {t} of the {N} requests Beyla counted; the rest were dropped before",
             "export, because Beyla is sampling traces. On a service that serves a few requests a minute,",
             "a ratio sampler throws away the request someone will come asking about.")
      print(f"PASS — {N} requests to ledger-legacy: {N} counted by Beyla and scraped by Prometheus, and")
      print(f"       {t} server spans in Tempo, with ledger_legacy.py unchanged.")
      PY
---
