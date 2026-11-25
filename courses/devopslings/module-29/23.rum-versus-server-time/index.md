---
kind: lesson
title: "The server answers in 80ms, and customers wait four seconds"
description: |
  checkout's server spans say p99 80ms. Customers on the support line say
  the checkout page takes four seconds, and the team's reply so far has been
  that the server is fast. You have a day of browser timings for the same
  page views. Say where the four seconds go, what the browser sees that a
  server span cannot, and what to instrument.
name: rum-versus-server-time
slug: rum-versus-server-time
createdAt: "2026-11-22"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      g=/var/lib/devopslings/rum
      rm -rf "$g" /obs/rum
      mkdir -p "$g" /obs/rum
      cat > "$g/views.py" <<'PY'
      # views.py OUTDIR — a day of checkout page views as the browser and the
      # server saw them. The render-blocking third-party script differs per run.
      import csv, json, math, os, random, sys
      out = sys.argv[1]
      third = [("https://cdn.consentwall.example/cmp.js", "consent banner"),
               ("https://edge.splitlab.example/flicker.js", "A/B test snippet")]
      random.shuffle(third)
      (block, _), (light, _) = third
      bundle = "https://shop.example/static/app.7c1e.js"
      beacon = "https://beacon.metricsly.example/rum-collector.js"
      nav = csv.writer(open(f"{out}/navigation.csv", "w"))
      res = csv.writer(open(f"{out}/resources.csv", "w"))
      srv = csv.writer(open(f"{out}/server.csv", "w"))
      nav.writerow(["view", "trace_id", "device", "country", "domainLookupStart", "domainLookupEnd", "connectStart",
                    "secureConnectionStart", "connectEnd", "requestStart", "responseStart", "responseEnd",
                    "domInteractive", "domContentLoadedEventEnd", "loadEventEnd"])
      res.writerow(["view", "name", "initiatorType", "renderBlockingStatus", "startTime", "responseEnd", "duration"])
      srv.writerow(["trace_id", "server_ms"])
      r = lambda x: round(x, 1)
      for v in range(1, 2001):
          mobile = random.random() < 0.6
          rtt = random.uniform(80, 200) if mobile else random.uniform(15, 50)
          dns = 0.0 if random.random() < 0.6 else random.uniform(10, 80)
          tcp = rtt * random.uniform(1.0, 1.2)
          tls = rtt * random.uniform(1.0, 1.3)
          server = min(random.lognormvariate(math.log(45), 0.25), 140)
          ttfb = server + rtt * random.uniform(1.0, 1.1)
          download = random.uniform(20, 90) * (1.5 if mobile else 1)
          ce = dns + tcp + tls
          rs = ce + ttfb
          re_ = rs + download
          head = re_ + random.uniform(30, 90)
          b = random.uniform(1500, 2600) * (1.25 if mobile else 1)
          a = random.uniform(200, 450) * (1.8 if mobile else 1)
          di = head + b + a + random.uniform(30, 80)
          dcl = di + random.uniform(10, 40)
          load = dcl + random.uniform(100, 300)
          tid = os.urandom(16).hex()
          nav.writerow([v, tid, "mobile" if mobile else "desktop", random.choice(["DE", "FR", "ES", "IT", "PL", "BR", "IN"]),
                        0, r(dns), r(dns), r(dns + tcp), r(ce), r(ce), r(rs), r(re_), r(di), r(dcl), r(load)])
          res.writerow([v, block, "script", "blocking", r(head), r(head + b), r(b)])
          res.writerow([v, bundle, "script", "blocking", r(head + b), r(head + b + a), r(a)])
          l = random.uniform(60, 180)
          res.writerow([v, light, "script", "non-blocking", r(head), r(head + l), r(l)])
          s = load + random.uniform(0, 50)
          d = random.uniform(2500, 5000)
          res.writerow([v, beacon, "script", "non-blocking", r(s), r(s + d), r(d)])
          srv.writerow([tid, r(server)])
      json.dump({"block": block, "light": light, "bundle": bundle, "beacon": beacon}, open(f"{out}/truth.json", "w"))
      PY
      python3 "$g/views.py" "$g"
      cp "$g"/navigation.csv "$g"/resources.csv "$g"/server.csv /obs/rum/
      cat > /obs/rum/README <<'TXT'
      A day of checkout page views, sampled 2,000 of them.

      navigation.csv  One row per page view, from the browser's Navigation Timing
                      (PerformanceNavigationTiming). Every timestamp is in ms from
                      the start of the navigation. trace_id is the server span the
                      page's HTML request produced.
      resources.csv   Resource Timing for each script the page loads: when it
                      started, when its response ended, how long that took, and
                      whether it blocks rendering (renderBlockingStatus).
      server.csv      The server's own time for the same requests, from checkout's
                      SERVER span, by trace_id.

      Customers on the support line: "the checkout page takes about four seconds".
      The team: "checkout's p99 is 80ms".
      TXT
      cat > /obs/answers/rum.txt <<'TXT'
      # Where the checkout page's time goes. '#' starts a comment.
      where: ?        # the phase most of the p75 page load is spent in: dns, tcp, tls, waiting, download or render
      where_ms: ?     # that phase's p75, in ms
      culprit: ?      # the thing in that phase that costs the most, by its URL from resources.csv
      server_ms: ?    # p75 of the server's own time (server.csv), in ms
      rum_sees: ?     # what the browser's timings measure that a server span cannot
      instrument: ?   # what to add, and where, so production shows this without a sampled CSV
      TXT
      echo "scenario ready: a day of checkout page views in /obs/rum (see /obs/rum/README)."
      echo "Your answer: /obs/answers/rum.txt"

  verify_done:
    timeout_seconds: 60
    run: |
      python3 - <<'PY'
      import csv, json, math, re, sys

      G = "/var/lib/devopslings/rum"
      ANSWER = "/obs/answers/rum.txt"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      try:
          truth = json.load(open(f"{G}/truth.json"))
          nav = list(csv.DictReader(open(f"{G}/navigation.csv")))
          res = list(csv.DictReader(open(f"{G}/resources.csv")))
          srv = [float(r["server_ms"]) for r in csv.DictReader(open(f"{G}/server.csv"))]
      except (OSError, ValueError):
          no("the scenario's files are missing. Reset the lesson.")

      def p75(xs):
          xs = sorted(xs)
          return xs[max(0, math.ceil(0.75 * len(xs)) - 1)]
      f = lambda r, k: float(r[k])
      phase = {
          "dns": p75([f(r, "domainLookupEnd") - f(r, "domainLookupStart") for r in nav]),
          "tcp": p75([f(r, "secureConnectionStart") - f(r, "connectStart") for r in nav]),
          "tls": p75([f(r, "connectEnd") - f(r, "secureConnectionStart") for r in nav]),
          "waiting": p75([f(r, "responseStart") - f(r, "requestStart") for r in nav]),
          "download": p75([f(r, "responseEnd") - f(r, "responseStart") for r in nav]),
          "render": p75([f(r, "loadEventEnd") - f(r, "responseEnd") for r in nav]),
      }
      page = p75([f(r, "loadEventEnd") for r in nav])
      server = p75(srv)
      dur = {u: p75([f(r, "duration") for r in res if r["name"] == u]) for u in truth.values()}

      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""

      def num(k):
          m = re.search(r"\d+(\.\d+)?", field(k).replace(",", ""))
          return float(m.group(0)) if m else None

      for k in ("where", "where_ms", "culprit", "server_ms", "rum_sees", "instrument"):
          if field(k) in ("", "?"):
              no(f"{k} in {ANSWER} is not filled in.")

      where = field("where").lower().strip()
      if where in ("server", "ttfb"):
          where = "waiting"
      if where not in phase:
          no(f"where is '{field('where')}'. It is one of dns, tcp, tls, waiting, download or render.")
      if where != "render":
          extra = ""
          if where == "waiting":
              extra = (f" That includes the server's own time, p75 {server:.0f}ms, and one network round trip.")
          no(f"where is {where}, whose p75 is {phase[where]:.0f}ms of a {page:.0f}ms page load.{extra}",
             "Work out each phase's p75 from navigation.csv and compare them.")
      w = num("where_ms")
      if w is None or abs(w - phase["render"]) > phase["render"] * 0.1:
          no(f"where_ms is '{field('where_ms')}'. Measure render as loadEventEnd minus responseEnd, per",
             "view, and take the 75th percentile; your number is more than 10% away from it.")

      c = field("culprit").lower()
      def names(u):
          host, path = re.match(r"https://([^/]+)(/.*)", u).groups()
          return host, path.rsplit("/", 1)[-1]
      hit = [k for k, u in truth.items() if any(n in c for n in names(u))]
      if hit == ["beacon"]:
          no(f"{names(truth['beacon'])[1]} has the longest duration in resources.csv, p75 {dur[truth['beacon']]:.0f}ms,",
             "and it starts after loadEventEnd: the page was already loaded. Duration says how long a",
             "fetch took, not whether anything waited for it.")
      if hit == ["bundle"]:
          no(f"the app bundle blocks rendering for p75 {dur[truth['bundle']]:.0f}ms. Something blocks it for",
             "longer. Look at what else is render-blocking, and when each one starts.")
      if hit == ["light"]:
          no(f"{names(truth['light'])[1]} is non-blocking and takes p75 {dur[truth['light']]:.0f}ms. It loads alongside",
             "the page rather than in front of it.")
      if hit != ["block"]:
          no(f"culprit is '{field('culprit')}'. Name the resource by its URL, or at least its host or",
             "file name, as resources.csv has it.")

      s = num("server_ms")
      if s is None or abs(s - server) > server * 0.2:
          no(f"server_ms is '{field('server_ms')}'. It is the 75th percentile of server.csv's server_ms;",
             "your number is more than 20% away from it.")

      seen = field("rum_sees").lower()
      groups = {
          "the network: DNS, connection set-up and TLS, round trips":
              r"\b(dns|tcp|tls|ssl|handshakes?|network|rtt|round[- ]trips?)\b",
          "what the browser does with the response: parsing, script execution, rendering":
              r"\b(render(ing)?|paint(ing)?|pars(e|ing)|layout|dom|javascript|js|script execution)\b",
          "third-party resources the page loads": r"\b(third[- ]party|3rd[- ]party)\b",
      }
      missing = [g for g, rx in groups.items() if not re.search(rx, seen)]
      if missing:
          no(f"rum_sees does not cover {missing[0]}. A server span starts when the request",
             "arrives and ends when the response leaves; name each kind of time outside it.")

      inst = field("instrument").lower()
      if not re.search(r"\b(rum|real[- ]user|browser|web sdk|sdk-trace-web|opentelemetry[- ]js|performanceobserver|"
                       r"navigation timing|resource timing|web[- ]vitals|lcp|inp|fcp)\b", inst):
          no(f"instrument is '{field('instrument')}'. More server spans cannot see any of this; say what runs",
             "in the browser and reports these timings from every real page view.")
      print(f"PASS — p75 page load {page:.0f}ms: render {phase['render']:.0f}ms, of which the render-blocking")
      print(f"{names(truth['block'])[1]} takes p75 {dur[truth['block']]:.0f}ms; the server's own time is p75 {server:.0f}ms.")
      PY
---
