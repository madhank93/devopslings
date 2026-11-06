---
kind: lesson
title: "Prometheus's memory tripled after shop's deploy"
description: |
  shop shipped a small change this morning, and since then Prometheus's
  memory has kept climbing. Giving it more memory buys an hour. Find the
  label that is multiplying shop's series, bring shop back under its series
  budget, and keep the per-endpoint latency and error questions answerable.
name: cardinality-explosion
slug: cardinality-explosion
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
      # This morning's deploy: label requests by the path a customer asked for.
      python3 - <<'PY'
      p = "/obs/apps/shop.py"
      s = open(p).read()
      for good, bad in [
          ('"HTTP requests served, by route template and status code.",\n    ["method", "route", "code"])',
           '"HTTP requests served, by path and status code.",\n    ["method", "path", "code"])'),
          ('["route"], buckets=', '["path"], buckets='),
          ('''            REQUESTS.labels("GET", route, str(code)).inc()
                  LATENCY.labels(route).observe(time.time() - start)''',
           '''            # Label by the exact path requested, so a slow order can be found by its ID.
                  path = self.path.split("?")[0]
                  REQUESTS.labels("GET", path, str(code)).inc()
                  LATENCY.labels(path).observe(time.time() - start)'''),
      ]:
          assert good in s, good
          s = s.replace(good, bad)
      open(p, "w").write(s)
      PY
      echo "scenario ready: shop was deployed this morning (/obs/apps/shop.py), and Prometheus's"
      echo "memory has climbed since. Its series count: promq 'prometheus_tsdb_head_series'."
      echo "Dashboards and alerts read shop_http_request_duration_seconds and"
      echo "shop_http_requests_total by route=\"/orders/:id\"."

  verify_done:
    timeout_seconds: 200
    run: |
      . /usr/local/lib/obs.sh
      BUDGET=150
      obs_require_loaded || exit 1

      # A save restarts shop; let the restart and one scrape after it land.
      edited=$(newest_mtime /obs/apps/shop.py /obs/run/shop.started)
      settle=$(( edited + 8 - $(date +%s) ))
      [ "$settle" -gt 0 ] && sleep "$settle"

      if ! prom_wait 'up{job="shop"} == 1' 20; then
        err=$(curl -s --max-time 10 "$PROM/api/v1/targets?scrapePool=shop" | jq -r '.data.activeTargets[0].lastError // empty' 2>/dev/null || true)
        echo "not yet: Prometheus cannot scrape shop (${err:-no answer})."
        if grep -q 'sample limit' <<<"$err"; then
          echo "sample_limit rejects the whole scrape once a target goes over it, so every shop metric"
          echo "is gone, not only the extra series. It protects Prometheus; it does not fix shop."
        fi
        started=$(cat /obs/run/shop.started 2>/dev/null || echo 0)
        log=$(tail -n 30 /obs/logs/shop.log 2>/dev/null || true)
        if [ $(( $(date +%s) - started )) -lt 10 ] && grep -q 'exited with status' <<<"$log"; then
          echo "shop is crashing on start. The end of /obs/logs/shop.log:"
          grep -v '^\[supervise\]' <<<"$log" | tail -n 8 | sed 's/^/  /'
        fi
        exit 1
      fi

      # New order IDs keep arriving, so a label made of them keeps growing.
      samples() { prom_val 'scrape_samples_post_metric_relabeling{job="shop"}'; }
      n1=$(samples); sleep 20; n2=$(samples)
      echo "shop: ${n1:-?} series per scrape, ${n2:-?} twenty seconds later (budget $BUDGET)"
      if [ "${n2:-0}" -gt "$BUDGET" ]; then
        # From shop's own endpoint: relabelling in Prometheus can hide the label
        # from queries without changing what shop exposes.
        worst=$(curl -s --max-time 5 http://shop:9101/metrics | python3 -c '
      import collections, re, sys
      vals = collections.defaultdict(set)
      for line in sys.stdin:
          if line.startswith("shop_"):
              for k, v in re.findall(r"(\w+)=\"([^\"]*)\"", line.split("}")[0]):
                  if k != "le":
                      vals[k].add(v)
      if vals:
          k = max(vals, key=lambda k: len(vals[k]))
          print(f"{k} ({len(vals[k])} values)")' 2>/dev/null || true)
        echo "not yet: shop exposes $n2 series per scrape, over its budget of $BUDGET, and it grows as"
        echo "customers arrive. The label with the most values: ${worst:-unknown}. Every distinct"
        echo "label value is a new series, in memory for as long as it is in the head block."
        if grep -q 'metric_relabel_configs' /obs/prometheus/prometheus.yml; then
          echo "Relabelling in prometheus.yml changes what Prometheus stores, not what shop exposes and"
          echo "Prometheus has to scrape and parse; the labels have to be fixed where they are made, in shop."
        fi
        exit 1
      fi

      # The question the label was meant to answer, as dashboards and alerts ask
      # it. Judge it on a minute of data that starts after the fix went live.
      loaded=$(date -d "$(curl -s --max-time 10 "$PROM/api/v1/status/runtimeinfo" | jq -r '.data.lastConfigTime' 2>/dev/null || true)" +%s 2>/dev/null || echo 0)
      since=$(newest_mtime /obs/run/shop.started)
      [ "$loaded" -gt "$since" ] && since=$loaded
      wait=$(( since + 70 - $(date +%s) ))
      if [ "$wait" -gt 0 ]; then
        echo "waiting ${wait}s for a full minute of data since the fix went live..."
        sleep "$wait"
      fi

      if [ "$(prom_count 'shop_http_requests_total{job="shop",route="/orders/:id"}')" = 0 ]; then
        have=$(prom_query 'shop_http_requests_total{job="shop"}' | jq -c '[.data.result[].metric | del(.__name__, .job, .instance, .method, .code)] | unique | .[:6]' 2>/dev/null || echo '[]')
        echo "not yet: shop_http_requests_total has no series with route=\"/orders/:id\" (it has: $have)."
        echo "Dashboards and alerts ask about the order-lookup endpoint by its route template; with"
        echo "that label gone, the question the label was added for cannot be asked at all."
        exit 1
      fi
      p99=$(prom_val 'histogram_quantile(0.99, sum by (le) (rate(shop_http_request_duration_seconds_bucket{job="shop",route="/orders/:id"}[1m])))')
      if [ -z "$p99" ] || [ "$p99" = NaN ]; then
        echo "not yet: the p99 latency of /orders/:id has no answer:"
        echo "  histogram_quantile(0.99, sum by (le) (rate(shop_http_request_duration_seconds_bucket{route=\"/orders/:id\"}[1m])))"
        echo "returns nothing. The latency histogram has to keep its buckets, labelled by route."
        exit 1
      fi

      num() { awk -v v="${1:-0}" 'BEGIN { printf "%.2f", v + 0 }'; }
      truth=$(num "$(prom_val 'sum(rate(loadgen_requests_total{target="shop",code!="0"}[1m]))')")
      got=$(num "$(prom_val 'sum(rate(shop_http_requests_total{job="shop"}[1m]))')")
      orders=$(num "$(prom_val 'sum(rate(shop_http_requests_total{job="shop",route="/orders/:id"}[1m]))')")
      echo "last minute: customers sent $truth req/s; shop counted $got, of them $orders to /orders/:id"
      if awk -v g="$got" -v t="$truth" 'BEGIN { d = g - t; if (d < 0) d = -d; exit !(d > 0.2 * t) }'; then
        dup=$(prom_val 'sum(increase(prometheus_target_scrapes_sample_duplicate_timestamp_total[1m]))')
        echo "not yet: shop's own counters say $got requests per second; customers sent $truth."
        if awk -v d="${dup:-0}" 'BEGIN { exit !(d > 0) }'; then
          echo "Prometheus is rejecting samples with duplicate labels ($(num "$dup") in the last minute,"
          echo "prometheus_target_scrapes_sample_duplicate_timestamp_total). Relabelling at scrape time"
          echo "merged series that shop still keeps apart: each scrape has many samples with the same"
          echo "labels, Prometheus keeps one and drops the rest, and the counts become nonsense. The"
          echo "labels have to be right where the series are made, in shop."
        else
          echo "The counts no longer add up to the traffic."
        fi
        exit 1
      fi
      if awk -v o="$orders" -v t="$truth" 'BEGIN { exit !(o < 0.1 * t || o > 0.35 * t) }'; then
        echo "not yet: /orders/:id gets about a fifth of shop's traffic, and its series show $orders of"
        echo "$truth req/s. Every order lookup has to be counted under route=\"/orders/:id\"."
        exit 1
      fi

      echo "PASS — shop is back to $n2 series per scrape, and /orders/:id still has its request"
      echo "rate and a p99 of $(num "$p99")s."
---
