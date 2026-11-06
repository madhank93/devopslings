---
kind: lesson
title: "forty panels, and nobody can say whether shop is up"
description: |
  shop's dashboard has forty panels. During last week's incident nobody could
  tell from it whether customers were being served, and the panels that
  looked like prod were showing staging. Turn it into a dashboard that answers
  the three questions on-call actually asks, for whichever environment is
  selected, and nothing else.
name: dashboard-that-answers-a-question
slug: dashboard-that-answers-a-question
createdAt: "2026-10-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      # One request in twenty fails, so the error ratio has something to show.
      echo 0.05 > /obs/run/shop.fault

      # shop runs in two environments: prod as shop:9101, staging as shop-2:9101.
      python3 - <<'PY'
      p = "/obs/prometheus/prometheus.yml"
      s = open(p).read()
      old = '''  - job_name: shop
          static_configs:
            - targets: ["shop:9101"]
      '''
      new = '''  - job_name: shop
          static_configs:
            - targets: ["shop:9101"]
              labels: {env: prod}
            - targets: ["shop-2:9101"]
              labels: {env: staging}
      '''
      assert old in s
      open(p, "w").write(s.replace(old, new))

      # The wall: every metric anyone ever wanted, three of them close to useful.
      R = "shop_http_requests_total"
      B = "shop_http_request_duration_seconds_bucket"
      panels = [
          ("Requests per second (prod)", f'sum(rate({R}{{env="prod"}}[1m]))'),
          ("Error ratio", f'sum(rate({R}{{code=~"5.."}}[1m])) / sum(rate({R}[1m]))'),
          ("Latency p50", f'histogram_quantile(0.5, sum by (le) (rate({B}[1m])))'),
          ("Latency p90", f'histogram_quantile(0.9, sum by (le) (rate({B}[1m])))'),
          ("Latency p95", f'histogram_quantile(0.95, sum by (le) (rate({B}[1m])))'),
          ("Average latency", 'sum(rate(shop_http_request_duration_seconds_sum[1m])) / sum(rate(shop_http_request_duration_seconds_count[1m]))'),
          ("Requests per minute", f'sum(rate({R}[1m])) * 60'),
          ("Requests: /", f'sum(rate({R}{{route="/"}}[1m]))'),
          ("Requests: /cart", f'sum(rate({R}{{route="/cart"}}[1m]))'),
          ("Requests: /search", f'sum(rate({R}{{route="/search"}}[1m]))'),
          ("Requests: /orders/:id", f'sum(rate({R}{{route="/orders/:id"}}[1m]))'),
          ("500s per second", f'sum(rate({R}{{code="500"}}[1m]))'),
          ("Total requests ever", f'sum({R})'),
          ("Latency p99 by route", f'histogram_quantile(0.99, sum by (le, route) (rate({B}[1m])))'),
          ("Error ratio by route", f'sum by (route) (rate({R}{{code=~"5.."}}[1m])) / sum by (route) (rate({R}[1m]))'),
          ("db queries per second", 'rate(db_queries_total[1m])'),
          ("db connections in use", 'db_pool_connections_in_use'),
          ("db queries waiting", 'db_pool_waiting_queries'),
          ("db refusals", 'rate(db_pool_acquire_timeouts_total[1m])'),
          ("Worker queue depth", 'worker_queue_depth'),
          ("Jobs processed", 'sum(rate(worker_jobs_processed_total[1m]))'),
          ("Backup age", 'time() - backup_last_success_timestamp_seconds'),
          ("Customer-seen requests", 'sum(rate(loadgen_requests_total{target="shop"}[1m]))'),
          ("Customer-seen p99", 'histogram_quantile(0.99, sum by (le) (rate(loadgen_request_duration_seconds_bucket{target="shop"}[1m])))'),
          ("Targets up", 'sum(up)'),
          ("Targets down", 'count(up == 0)'),
          ("shop CPU", 'rate(process_cpu_seconds_total{job="shop"}[1m])'),
          ("shop memory", 'process_resident_memory_bytes{job="shop"}'),
          ("shop open files", 'process_open_fds{job="shop"}'),
          ("shop max files", 'process_max_fds{job="shop"}'),
          ("shop GC collections", 'sum(rate(python_gc_collections_total{job="shop"}[1m]))'),
          ("shop GC objects", 'sum(rate(python_gc_objects_collected_total{job="shop"}[1m]))'),
          ("shop start time", 'process_start_time_seconds{job="shop"}'),
          ("Scrape duration", 'scrape_duration_seconds'),
          ("Samples scraped", 'sum(scrape_samples_scraped)'),
          ("Prometheus head series", 'prometheus_tsdb_head_series'),
          ("Prometheus rule evaluations", 'rate(prometheus_rule_evaluations_total[1m])'),
          ("Prometheus memory", 'process_resident_memory_bytes{job="prometheus"}'),
          ("Prometheus HTTP requests", 'sum(rate(prometheus_http_requests_total[1m]))'),
          ("Python version", 'python_info'),
      ]
      ds = {"type": "prometheus", "uid": "prometheus"}
      out = []
      for i, (title, expr) in enumerate(panels):
          out.append({"id": i + 1, "type": "timeseries", "title": title, "datasource": ds,
                      "gridPos": {"x": (i % 4) * 6, "y": (i // 4) * 5, "w": 6, "h": 5},
                      "targets": [{"refId": "A", "expr": expr}]})
      import json
      json.dump({"uid": "shop", "title": "Shop overview", "time": {"from": "now-1h", "to": "now"},
                 "refresh": "10s", "panels": out, "schemaVersion": 41},
                open("/obs/grafana/dashboards/shop.json", "w"), indent=2)
      PY
      chmod -R a+rX /obs/prometheus /obs/grafana
      obs-reload >/dev/null
      echo "scenario ready: the dashboard is /obs/grafana/dashboards/shop.json, \"Shop overview\" at"
      echo "http://localhost:13000/d/shop. Grafana rereads the file every 5 seconds."
      echo "shop runs as env=\"prod\" and env=\"staging\"."

  verify_done:
    timeout_seconds: 240
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1
      # Right after the scenario's reload, staging may not have been scraped yet.
      prom_wait 'shop_http_requests_total{env="staging"}' 30 || true
      python3 - <<'PY'
      import json, re, statistics, sys, time, urllib.parse, urllib.request

      PROM, GRAFANA = "http://prometheus:9090", "http://grafana:3000"
      FILE = "/obs/grafana/dashboards/shop.json"

      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          try:
              return json.load(urllib.request.urlopen(url, timeout=15))
          except Exception:
              return None

      def flat(panels):
          for p in panels or []:
              yield p
              yield from flat(p.get("panels"))

      # The dashboard as Grafana serves it, once it has caught up with the file.
      try:
          on_disk = json.load(open(FILE))
      except FileNotFoundError:
          fail(f"{FILE} is gone. Edit the dashboard in place; keep its uid \"shop\".")
      except ValueError as e:
          fail(f"{FILE} is not valid JSON ({e}), so Grafana keeps showing the old version.")
      if on_disk.get("uid") != "shop":
          fail(f"the dashboard in {FILE} has uid {on_disk.get('uid')!r}; keep it as \"shop\", the link on-call has.")
      # Grafana rereads the file every few seconds; grade only the version on disk.
      def sig(dash):
          panels = [(p.get("type"), p.get("title"), ((p.get("fieldConfig") or {}).get("defaults") or {}).get("unit"),
                     [(t.get("expr"), bool(t.get("hide"))) for t in p.get("targets") or []])
                    for p in flat(dash.get("panels"))]
          vars_ = [(v.get("name"), v.get("type"), v.get("query")) for v in (dash.get("templating") or {}).get("list", [])]
          return json.dumps([panels, vars_], sort_keys=True)
      want = sig(on_disk)
      dash = None
      for _ in range(20):
          d = get(f"{GRAFANA}/api/dashboards/uid/shop")
          if d and sig(d["dashboard"]) == want:
              dash = d["dashboard"]
              break
          time.sleep(1)
      if dash is None:
          fail(f"Grafana has not loaded {FILE} as it is now. Its log says why:",
               "  docker compose logs grafana   (from the host), or open http://localhost:13000/d/shop")

      # The env variable, and the values it offers.
      var = next((v for v in dash.get("templating", {}).get("list", []) if v.get("name") == "env"), None)
      if var is None:
          fail("the dashboard has no variable named env. One dashboard has to serve prod and staging;",
               "a variable lets the reader pick, and every panel filters on it.")
      q = var.get("query")
      q = q.get("query", "") if isinstance(q, dict) else (q or "")
      if var.get("type") == "custom":
          options = {o.strip() for o in q.split(",")}
      elif var.get("type") == "query":
          m = re.fullmatch(r"\s*label_values\(\s*(?:(.+?)\s*,\s*)?env\s*\)\s*", q)
          if not m:
              fail(f"the env variable's query is {q!r}. label_values(<metric>, env) lists the env values a",
                   "metric has.")
          params = {"match[]": m.group(1)} if m.group(1) else {}
          r = get(f"{PROM}/api/v1/label/env/values?" + urllib.parse.urlencode(params)) or {}
          options = set(r.get("data") or [])
      else:
          options = set()
      if not {"prod", "staging"} <= options:
          fail(f"the env variable offers {sorted(options) or 'nothing'}; it has to offer prod and staging.")

      # PromQL as Grafana would send it with env set to a value.
      def render(expr, env):
          for pat in (r"\$\{env(?::[a-z]+)?\}", r"\[\[env\]\]", r"\$env\b"):
              expr = re.sub(pat, env, expr)
          return re.sub(r"\$__(rate_interval|interval|range)\b|\$\{__(rate_interval|interval|range)\}", "1m", expr)

      # Median over the last three minutes of the per-step sum of every series.
      end = time.time()
      def series(expr):
          r = get(f"{PROM}/api/v1/query_range?" + urllib.parse.urlencode(
              {"query": expr, "start": end - 180, "end": end, "step": 15}))
          if not r or r.get("status") != "success":
              return None, (r or {}).get("error", "query failed")
          steps = {}
          for s in r["data"]["result"]:
              for t, v in s["values"]:
                  v = float(v)
                  if v == v and abs(v) != float("inf"):
                      steps[t] = steps.get(t, 0) + v
          return (statistics.median(steps.values()) if steps else None), None

      R, B = "shop_http_requests_total", "shop_http_request_duration_seconds_bucket"
      questions = [
          ("requests per second", f'sum(rate({R}{{env="prod"}}[1m]))', 1),
          ("the fraction of requests failing",
           f'sum(rate({R}{{env="prod",code=~"5.."}}[1m])) / sum(rate({R}{{env="prod"}}[1m]))', 100),
          ("the p99 latency", f'histogram_quantile(0.99, sum by (le) (rate({B}{{env="prod"}}[1m])))', 1),
      ]
      # Right after a start, shop may not have failed a request yet, so the error
      # ratio has nothing to divide; give it up to 90 seconds.
      for _ in range(18):
          end = time.time()
          truth = [series(expr)[0] for _, expr, _ in questions]
          if None not in truth:
              break
          time.sleep(5)
      else:
          fail("Prometheus has no shop data for env=\"prod\" yet; wait a minute and retry.")

      # A panel's unit says which question it claims to answer, and in what scale.
      UNITS = {"reqps": (0, 1), "rps": (0, 1), "ops": (0, 1),
               "percentunit": (1, 1), "percent": (1, 100), "s": (2, 1), "ms": (2, 1000)}
      answered = set()
      for p in flat(dash.get("panels")):
          if p.get("type") == "row":
              continue
          title = p.get("title") or f"panel {p.get('id')}"
          unit = ((p.get("fieldConfig") or {}).get("defaults") or {}).get("unit")
          exprs = [t.get("expr") for t in p.get("targets") or [] if t.get("expr") and not t.get("hide")]
          if unit not in UNITS or not exprs:
              fail(f"panel \"{title}\" answers none of the three questions: requests per second, the",
                   "fraction failing, the p99 latency. Every panel is something a reader at 3am has to",
                   "look at and dismiss, so one that answers none has to go.",
                   "(A panel that does answer one says so with its unit: reqps, percentunit or percent,",
                   f"s or ms. This one's unit is {unit or 'not set'}.)")
          i, k = UNITS[unit]
          name, want = questions[i][0], truth[i] * k
          for e in exprs:
              v, err = series(render(e, "prod"))
              if err:
                  fail(f"panel \"{title}\" has a query Prometheus rejects with env=prod: {err}")
              # Before the value check: an unfiltered sum is off by the other
              # environment's share, and the cause to name is the missing filter.
              if series(render(e, "devopslings-no-such-env"))[0] is not None:
                  fail(f"panel \"{title}\" shows the same data whatever env is selected. Its query",
                       f"  {e}",
                       *(["names one environment itself, so a reader who picks staging still sees prod."]
                         if re.search(r'env\s*=~?\s*"[^$"]', e) else
                         ["does not filter on the env variable, so a reader looking at staging sees prod",
                          "and staging mixed."]),
                       "Filter on env=\"$env\".")
              if v is None or abs(v - want) > 0.25 * want + 1e-9:
                  got = "no data" if v is None else f"{v:.3f}"
                  r = get(f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": render(e, "prod")})) or {}
                  n = len((r.get("data") or {}).get("result") or [])
                  more = [] if n < 2 else [
                      f"It returns {n} series, which together read {got}. A ratio or a quantile of several",
                      "series is not the sum of the per-series answers: aggregate first, sum by (le) before",
                      "histogram_quantile, sum the top and the bottom before dividing."]
                  if unit == "percent" and v is not None and abs(v * 100 - want) <= 0.25 * want + 1e-9:
                      more += ["The unit percent expects 0 to 100 and this query gives a fraction from 0 to 1:",
                               "use the unit percentunit, or multiply by 100."]
                  fail(f"panel \"{title}\" is in {unit}, so it shows {name}, and it reads {got} for prod;",
                       f"Prometheus says {want:.3f}.  {questions[i][1]}  computes it.", *more)
              if series(render(e, "staging"))[0] is None:
                  fail(f"panel \"{title}\" has no data with env=staging. Check how it uses $env.")
          answered.add(i)

      for i, (name, expr, _) in enumerate(questions):
          if i not in answered:
              fail(f"no panel shows {name} for the selected environment. For prod it is {truth[i]:.3f};",
                   f"one way to compute it:  {expr.replace(chr(34) + 'prod' + chr(34), chr(34) + '$env' + chr(34))}")

      n = sum(1 for p in flat(dash.get("panels")) if p.get("type") != "row")
      print(f"PASS — {n} panel(s), each answering one of the three questions for the selected env:")
      print(f"  prod now: {truth[0]:.2f} req/s, {truth[1] * 100:.1f}% failing, p99 {truth[2]:.3f}s")
      PY
---
