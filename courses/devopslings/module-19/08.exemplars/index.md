---
kind: lesson
title: "checkout's p99 is over a second, and no trace anyone has opened is slow"
description: |
  checkout's latency histogram says one order in a hundred takes more than a
  second. Tempo has every order's trace, and the ones people pick at random
  all take a tenth of that. Join the two: make the slow buckets of the
  histogram point at the traces that landed in them, then say what makes
  those orders slow.
name: exemplars
slug: exemplars
createdAt: "2026-11-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: checkout
          # Pinned when checkout still used an exporter library that served
          # this format and nothing newer.
          scrape_protocols: [PrometheusText0.0.4]
          static_configs:
            - targets: ["checkout:9101"]
      YML
      obs_reload >/dev/null
      for a in broker ledger fulfil checkout; do app_up "$a"; done
      echo "scenario ready: checkout records every order in checkout_duration_seconds and"
      echo "sends its trace to Tempo; Prometheus scrapes checkout:9101. The p99:"
      echo "  promq 'histogram_quantile(0.99, sum by (le) (rate(checkout_duration_seconds_bucket[2m])))'"

  verify_done:
    timeout_seconds: 150
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      PROM, TEMPO = "http://prometheus:9090", "http://tempo:3200"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url, **params):
          with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}" if params else url, timeout=10) as r:
              return json.load(r)

      def scraped():
          """checkout's exemplars as Prometheus would read them: (labels, value) of each."""
          req = urllib.request.Request("http://checkout:9101/metrics",
                                       headers={"Accept": "application/openmetrics-text; version=1.0.0"})
          try:
              text = urllib.request.urlopen(req, timeout=5).read().decode()
          except OSError as e:
              no(f"checkout's /metrics on checkout:9101 does not answer ({getattr(e, 'reason', e)}). The end of",
                 "/obs/logs/checkout.log:", *["  " + l.rstrip()[:200] for l in open("/obs/logs/checkout.log").readlines()[-4:]])
          out = []
          for l in text.splitlines():
              m = re.match(r'checkout_duration_seconds_bucket\{.*\} \S+ # \{(.*)\} (\S+)', l)
              if m:
                  labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
                  out.append((labels, float(m.group(2))))
          return out

      # An order slower than a second lands about once every ten seconds.
      time.sleep(1.5)
      since = int(open("/obs/run/checkout.started").read())
      time.sleep(max(0, since + 5 - time.time()))
      ex = []
      for i in range(60):
          ex = scraped()
          if any(v > 1 for _, v in ex) or (i >= 10 and not ex):
              break
          time.sleep(1)
      if not ex:
          no("checkout's /metrics has no exemplars on checkout_duration_seconds. An exemplar is",
             "attached when an observation is made: DURATION.observe(value, exemplar={...}).")
      names = sorted({k for labels, _ in ex for k in labels})
      if "trace_id" not in names:
          no(f"checkout's exemplars carry {', '.join(names)}. Grafana's Prometheus datasource opens",
             "the exemplar label trace_id in Tempo, and nothing else.")
      ids = [labels["trace_id"] for labels, _ in ex]
      if all(re.fullmatch(r"0+", i) for i in ids):
          no("every exemplar's trace_id is all zeros: the observation is made when no span is",
             "current, and the SDK hands out an invalid one. Take the trace id from the order's",
             "own span.")
      bad = [i for i in ids if not re.fullmatch(r"[0-9a-f]{32}", i)]
      if bad:
          no(f"an exemplar's trace_id is {bad[0]!r}. Tempo, and Grafana's link",
             "to it, expect the W3C form: 32 lowercase hex digits, zero-padded, as",
             "format(trace_id, \"032x\") gives.")

      # Prometheus's copy, which is what a panel and an alert see.
      stored = []
      for i in range(40):
          res = get(f"{PROM}/api/v1/query_exemplars", query="checkout_duration_seconds_bucket",
                    start=since, end=int(time.time())).get("data") or []
          stored = [e for s in res for e in s["exemplars"]]
          if any(float(e["value"]) > 1 for e in stored) or (i >= 12 and not stored):
              break
          time.sleep(1)
      if not stored:
          job = next((j for j in get(f"{PROM}/api/v1/status/config")["data"]["yaml"].split("- job_name:")
                      if j.strip().startswith("checkout")), "")
          protos = re.search(r"scrape_protocols:\s*\n((?:\s+- .*\n)+)", job)
          shown = ", ".join(re.findall(r"- (\S+)", protos.group(1))) if protos else "the default"
          no("checkout serves exemplars and Prometheus has stored none of them. Exemplars exist",
             "only in the OpenMetrics format; Prometheus asks checkout for", f"  scrape_protocols: {shown}")

      slow = sorted((e for e in stored if float(e["value"]) > 1), key=lambda e: -float(e["value"]))
      if not slow:
          no("Prometheus has exemplars for checkout_duration_seconds, and none for an order slower",
             "than a second yet. Give it half a minute and check again.")

      def spans(tid):
          try:
              t = get(f"{TEMPO}/api/traces/{tid}")
          except urllib.error.HTTPError:
              return []
          out = []
          for b in t.get("batches") or t.get("resourceSpans") or t.get("trace", {}).get("resourceSpans", []):
              for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
                  out += ss.get("spans", [])
          return out

      e = slow[0]
      tid, value = e["labels"]["trace_id"], float(e["value"])
      ss = []
      for _ in range(10):
          ss = spans(tid)
          if ss:
              break
          time.sleep(1)
      if not ss:
          no(f"the exemplar for a {value:.2f}s order names trace {tid}, and Tempo has no such trace.")
      def took(s):
          return (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e9
      def describe(s):
          attrs = {a["key"]: next(iter(a["value"].values())) for a in s.get("attributes", [])}
          note = [f"{k}={v}" for k, v in attrs.items() if k != "order.id"]
          if s.get("status", {}).get("message"):
              note.append(f"error: {s['status']['message']}")
          return f"  {s['name']}  {took(s):.2f}s" + (f"  ({', '.join(note)})" if note else "")
      root = max((took(s) for s in ss if s["name"] == "POST /checkout"), default=0)
      if root < value * 0.8:
          no(f"the exemplar for a {value:.2f}s order points at trace {tid},",
             f"which is not that order. Its spans: {', '.join(sorted({s['name'] for s in ss}))}, the longest",
             f"{max(took(s) for s in ss):.2f}s. The exemplar has to name the trace of the request the",
             "observation measured.")

      try:
          ans = open("/obs/answers/exemplars.txt").read()
      except OSError:
          ans = ""
      m = re.search(r"^\s*cause\s*:(.*)$", ans, re.M | re.I)
      if not m or not m.group(1).strip():
          no("/obs/answers/exemplars.txt needs a line `cause: …` saying what makes the slow",
             f"orders slow. The slowest exemplar is trace {tid}.")
      cause = m.group(1).lower()
      if not re.search(r"\bcoupon", cause) or not re.search(r"time ?out|timed out|retr(y|ies|ied)|\b1 ?s\b|second", cause):
          top = sorted((s for s in ss if s["name"] != "POST /checkout"), key=took, reverse=True)[:4]
          no(f"the answer gives the cause as {m.group(1).strip()!r}.",
             f"Trace {tid}, a {value:.2f}s order, spent its time in:", *[describe(s) for s in top],
             "Say which step is slow, and why it takes as long as it does.")
      print("PASS — checkout's slow buckets link to the traces that landed in them. The slowest,")
      print(f"{tid} ({value:.2f}s), spends its time in a coupon lookup that times out and is retried.")
      PY
---
