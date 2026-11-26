---
kind: lesson
title: "300 ms in one span, and nothing underneath it"
description: |
  Tempo shows price-quote taking 300 ms, and the trace ends there: no child
  spans, nothing to say where the time went. Adding spans until one is slow
  stops at the function boundary, and the slow part is a loop. Link the
  trace to the profile taken while that span ran, read the function off it,
  and bring the span under budget.
name: span-profiles
slug: span-profiles
createdAt: "2026-11-22"

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
      # Stop every profiled app this module starts, whichever lesson left it running:
      # they share the CPU this lesson's numbers are read from.
      pkill -f '^bash [^ ]*/supervise (pricing|catalog-v[12]|quoter|quotes) ' 2>/dev/null || true
      pkill -f '^python3 /obs/(pricing|catalog|quoter|quotes)/' 2>/dev/null || true
      rm -rf /obs/quoter /obs/run/quoter.* /obs/logs/quoter.log
      mkdir -p /obs/quoter

      cat > /obs/quoter/quoter.py <<'PY'
      """quoter: prices insurance quotes off the queue. Each quote is one trace,
      rooted at a "price-quote" span, sent to Tempo; the process profiles itself
      to Pyroscope as service "quoter"."""
      import math, os, random, time

      import pyroscope
      from opentelemetry import trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      pyroscope.configure(application_name="quoter",
                          server_address=os.environ.get("PYROSCOPE", "http://pyroscope:4040"), sample_rate=100)
      provider = TracerProvider(resource=Resource.create({"service.name": "quoter"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("quoter")

      RIDERS = {"accident": 1.08, "travel": 1.03, "dental": 1.05, "optical": 1.02, "legal": 1.01,
                "income": 1.12, "critical": 1.15, "hospital": 1.07, "pet": 1.01, "gadget": 1.02,
                "home": 1.04, "breakdown": 1.03}


      def mortality_table():
          """Gompertz-Makeham survival probabilities by age, 0-119."""
          table = []
          for age in range(120):
              hazard = 0.0005 + 0.00003 * math.exp(0.1 * age)
              survive = 1.0
              for _ in range(3500):
                  survive *= math.exp(-hazard / 3500)
              table.append(survive)
          return table


      def base_premium(age, region):
          return 120.0 * (1.2 if region == "UK" else 1.0) * (1 + age / 100)


      def rider_premium(rider, age):
          return 30.0 * RIDERS[rider] * (1 - mortality_table()[age])


      def price_quote(q):
          with tracer.start_as_current_span("price-quote") as span:
              span.set_attribute("quote.riders", len(q["riders"]))
              total = base_premium(q["age"], q["region"])
              for rider in q["riders"]:
                  total += rider_premium(rider, q["age"])
              return round(total, 2)


      rng = random.Random()
      while True:
          price_quote({"age": rng.randint(18, 80), "region": rng.choice(["UK", "EU"]),
                       "riders": rng.sample(sorted(RIDERS), 12)})
          time.sleep(1)
      PY
      chmod -R a+rX /obs/quoter
      cp /obs/quoter/quoter.py /obs/run/quoter.orig.py

      for _ in $(seq 1 60); do curl -fs -m 2 "$PYROSCOPE/ready" >/dev/null 2>&1 && break; sleep 1; done
      setsid supervise quoter python3 /obs/quoter/quoter.py </dev/null >/dev/null 2>&1 &

      q='{resource.service.name="quoter" && name="price-quote"}'
      n=0
      for _ in $(seq 1 60); do
        n=$(curl -s -m 5 -G "$TEMPO/api/search" --data-urlencode "q=$q" \
              --data-urlencode start=$(( $(date +%s) - 300 )) --data-urlencode end=$(date +%s) |
            jq '.traces | length' 2>/dev/null || echo 0)
        [ "${n:-0}" -gt 0 ] && break
        sleep 2
      done
      if [ "${n:-0}" = 0 ]; then
        echo "scenario setup failed: no price-quote trace from quoter reached Tempo" >&2
        tail -5 /obs/logs/quoter.log >&2 || true
        exit 1
      fi

      echo "scenario ready — quoter prices a quote a second; each is a trace in Tempo rooted at a"
      echo "price-quote span (Grafana http://localhost:13000, Explore, Tempo:"
      echo "  {resource.service.name=\"quoter\" && name=\"price-quote\"}). The code: /obs/quoter/quoter.py"

  verify_done:
    timeout_seconds: 300
    run: |
      python3 - <<'PY'
      import ast, http.client, json, subprocess, sys, textwrap, time, urllib.parse, urllib.request

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      ans = {}
      try:
          for line in open("/obs/answers/span.txt"):
              if "=" in line:
                  k, v = line.split("=", 1)
                  ans[k.strip()] = v.strip().strip('"')
      except OSError:
          pass
      fn = ans.get("function", "").split(".")[-1].split("(")[0].strip()
      if not fn:
          no("/obs/answers/span.txt needs function=<name>: the function the profile linked to a slow",
             "price-quote span shows the time in.")
      if fn in ("price_quote", "<module>"):
          no(f"function={fn} is the span itself; the profile of the span is everything under it.",
             "Follow its widest child down.")
      if fn == "rider_premium":
          no("function=rider_premium is wide, but its own self time is small: it calls the function",
             "that does the work. Name that one.")
      if fn != "mortality_table":
          no(f"function={fn}. Open a price-quote span's profile from the trace view and read the",
             "widest frame under price_quote.")

      def load(path):
          """quoter's definitions without its side effects: no main loop, no exporter or profiler setup."""
          tree = ast.parse(open(path).read())
          tree.body = [n for n in tree.body if not isinstance(n, (ast.While, ast.Expr))]
          ns = {"__name__": "quoter_check"}
          exec(compile(tree, path, "exec"), ns)
          return ns

      sample = [{"age": a, "region": r, "riders": ["accident", "income", "critical", "pet"]}
                for a, r in ((18, "UK"), (47, "EU"), (80, "UK"))]
      try:
          mine = [load("/obs/quoter/quoter.py")["price_quote"](q) for q in sample]
      except Exception as e:
          no(f"/obs/quoter/quoter.py fails when this check prices a sample quote: {e!r}")
      orig = [load("/obs/run/quoter.orig.py")["price_quote"](q) for q in sample]
      if mine != orig:
          no(f"quoter prices the same quotes differently now: {mine} against {orig} before.",
             "The table is slow to build, not wrong; make it cheaper without changing what it holds.")

      def fetch(req, what):
          try:
              return json.load(urllib.request.urlopen(req, timeout=15)) or {}
          except (OSError, ValueError, http.client.HTTPException) as e:
              no(f"{what} did not answer this check's query: {e}")

      def search(q, since):
          url = "http://tempo:3200/api/search?" + urllib.parse.urlencode(
              {"q": q, "start": since, "end": int(time.time()) + 1, "limit": 50, "spss": 1})
          return fetch(url, "Tempo").get("traces") or []

      try:
          started = int(open("/obs/run/quoter.started").read())
      except (OSError, ValueError):
          no("quoter is not running under its supervisor (/obs/run/quoter.started is missing or empty).",
             "It restarts by itself when quoter.py changes; check /obs/logs/quoter.log.")
      since = started + 3
      time.sleep(max(0, since + 2 - time.time()))
      # Tempo makes a trace searchable only once the trace has been idle for a while (~10 s).
      deadline = max(time.time(), started) + 60
      while True:
          allq = search('{resource.service.name="quoter" && name="price-quote"}', since)
          if len(allq) >= 3 or time.time() > deadline:
              break
          time.sleep(3)
      try:
          tail = [l.rstrip()[:200] for l in open("/obs/logs/quoter.log").readlines()[-3:]]
      except OSError:
          tail = ["(no log)"]
      if len(allq) < 3:
          no(f"Tempo has {len(allq)} price-quote traces since quoter last restarted; it should be one a",
             "second. The end of /obs/logs/quoter.log:",
             *tail)
      linked = search('{resource.service.name="quoter" && name="price-quote" && span.pyroscope.profile.id != nil}', since)
      if len(linked) < len(allq):
          no(f"{len(allq) - len(linked)} of the {len(allq)} latest price-quote spans carry no pyroscope.profile.id,",
             "so nothing links them to a profile. pyroscope-otel's PyroscopeSpanProcessor, added to",
             "quoter's TracerProvider, marks each root span and labels the samples taken during it.")
      # PyroscopeSpanProcessor uses the span's own id as its profile id, and labels the samples
      # with it. Any other value on a real span points at a profile nobody recorded.
      sel = search('{resource.service.name="quoter" && name="price-quote"} | select(span.pyroscope.profile.id)', since)
      def norm(h):
          h = str(h).lower()
          return (h[2:] if h.startswith("0x") else h).lstrip("0")
      examined = 0
      for t in sel:
          sets = (t.get("spanSets") or []) + ([t["spanSet"]] if t.get("spanSet") else [])
          for sp in (sp for ss in sets for sp in ss.get("spans") or []):
              examined += 1
              got = next((a["value"].get("stringValue", "") for a in sp.get("attributes") or []
                          if a.get("key") == "pyroscope.profile.id"), "")
              if not got or norm(got) != norm(sp.get("spanID", "")):
                  no(f"price-quote span {sp.get('spanID')} carries pyroscope.profile.id={got!r}, not its own span id.",
                     "The profile samples are labelled with the span id; an id set by hand links to nothing.")
      if sel and not examined:
          no(f"Tempo matched {len(sel)} price-quote traces but returned none of their spans, so this check",
             "cannot read their pyroscope.profile.id. Run the check again.")
      # The id must lead to samples: run quoter's own setup, burn CPU in one root span of its
      # tracer, and ask Pyroscope for that span's profile.
      probe = r'''
      import ast, json, time, pyroscope
      from opentelemetry import trace
      tree = ast.parse(open("/obs/quoter/quoter.py").read())
      tree.body = [n for n in tree.body if not isinstance(n, ast.While)]
      exec(compile(tree, "/obs/quoter/quoter.py", "exec"), {"__name__": "quoter_check"})
      with trace.get_tracer("verify").start_as_current_span("profile-link-check") as span:
          t0 = time.process_time()
          while time.process_time() - t0 < 2:
              sum(i * i for i in range(10000))
      trace.get_tracer_provider().shutdown()
      pyroscope.shutdown()
      print(json.dumps({"id": span.attributes.get("pyroscope.profile.id")}))
      '''
      try:
          r = subprocess.run(["python3", "-c", textwrap.dedent(probe)], capture_output=True, text=True, timeout=40)
      except subprocess.TimeoutExpired:
          no("a 2-second span run through quoter's tracing setup took over 40 s to finish and flush.")
      try:
          pid = json.loads(r.stdout.strip().splitlines()[-1])["id"]
      except (IndexError, ValueError, KeyError):
          no("/obs/quoter/quoter.py fails when this check runs its tracing setup:", *r.stderr.strip().splitlines()[-3:])
      if not pid:
          no("a root span started from quoter's TracerProvider gets no pyroscope.profile.id. Setting the",
             "attribute by hand in price_quote links nothing; the span processor sets it on every root span.")
      body = json.dumps({"profileTypeID": "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
                         "labelSelector": '{service_name="quoter"}', "spanSelector": [pid],
                         "start": int(time.time() - 120) * 1000, "end": int(time.time() + 60) * 1000}).encode()
      ticks, deadline = 0, time.time() + 60
      while not ticks and time.time() < deadline:
          req = urllib.request.Request("http://pyroscope:4040/querier.v1.QuerierService/SelectMergeSpanProfile",
                                       data=body, headers={"Content-Type": "application/json"})
          ticks = int((fetch(req, "Pyroscope").get("flamegraph") or {}).get("total") or 0)
          if not ticks:
              time.sleep(3)
      if not ticks:
          no(f"a 2-second span this check ran through quoter's setup has pyroscope.profile.id={pid}, and",
             "after 60 s Pyroscope still holds no samples for it: not ingested, or never labelled. The id",
             "links a profile only if the samples taken during the span carry it, as PyroscopeSpanProcessor does.")

      full = search('{resource.service.name="quoter" && name="price-quote" && span.quote.riders = 12}', since)
      if len(full) < len(allq):
          no(f"{len(allq) - len(full)} of the {len(allq)} latest price-quote spans priced fewer than 12 riders.",
             "Customers pick their riders; the span has to get fast on the quotes they send.")
      ms = sorted(t.get("durationMs", 0) for t in allq)
      p90 = ms[int(0.9 * (len(ms) - 1))]
      print(f"Tempo since quoter's last restart: {len(allq)} price-quote spans, p90 {p90} ms, all linked to profiles")
      if p90 >= 100:
          no(f"price-quote's p90 is {p90} ms; the budget is 100 ms.")
      print(f"PASS — mortality_table was rebuilt for every rider; price-quote now takes {p90} ms at p90,")
      print("       and each span links to the profile taken while it ran.")
      PY
---
