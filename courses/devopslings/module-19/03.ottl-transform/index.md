---
kind: lesson
title: "Access logs carry one field that dashboards need as three"
description: |
  The edge proxy logs every request as one string, "GET /cart 200", and the
  dashboards want method, path and status code as separate attributes of the
  right types. The first transform splits it, under the wrong names, and
  when one malformed record arrives it takes the good records in the same
  batch down with it. Reshape the records with OTTL, and drop the bad ones
  without losing anything else.
name: ottl-transform
slug: ottl-transform
createdAt: "2026-11-14"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      cat > /obs/otel/collector.yaml <<'YML'
      # Access logs from the edge proxy. Each record has one attribute,
      # request = "METHOD PATH STATUS". Output goes to /obs/otel/out/access.jsonl,
      # one OTLP JSON export per line. Saving this file restarts the Collector;
      # its output is in /obs/logs/collector.log.
      receivers:
        otlp:
          protocols:
            http:
              endpoint: 0.0.0.0:4318

      processors:
        transform/request:
          error_mode: propagate
          log_statements:
            - context: log
              statements:
                - merge_maps(attributes, ExtractPatterns(attributes["request"], "^(?P<method>\\S+) (?P<path>\\S+) (?P<status>\\S+)$"), "upsert")

      exporters:
        file:
          path: /obs/otel/out/access.jsonl
          flush_interval: 200ms

      service:
        telemetry:
          metrics:
            readers:
              - pull:
                  exporter:
                    prometheus:
                      host: 0.0.0.0
                      port: 8888
        pipelines:
          logs:
            receivers: [otlp]
            processors: [transform/request]
            exporters: [file]
      YML
      rm -f /obs/otel/out/access.jsonl
      python3 - <<'PY'
      import json
      def rec(body, value):
          attrs = [] if value is None else [{"key": "request", "value": value}]
          return {"severityText": "INFO", "body": {"stringValue": body}, "attributes": attrs}
      records = [
          rec("ok", {"stringValue": "GET /cart 200"}),
          rec("ok", {"stringValue": "POST /payments/charge 503"}),
          rec("truncated by the proxy", {"stringValue": "GET /search?q=bo"}),
          rec("proxy restarted", None),
          rec("client sent a number", {"intValue": "404"}),
      ]
      body = {"resourceLogs": [{"resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "edge-proxy"}}]},
          "scopeLogs": [{"logRecords": records}]}]}
      json.dump(body, open("/obs/otel/sample-access.json", "w"), indent=1)
      PY
      . /usr/local/lib/obs.sh
      collector_settle >/dev/null || true
      echo "scenario ready: the Collector runs /obs/otel/collector.yaml and writes what it exports to"
      echo "/obs/otel/out/access.jsonl. A sample batch, two good records and three malformed ones:"
      echo "  curl -H 'Content-Type: application/json' http://collector:4318/v1/logs -d @/obs/otel/sample-access.json"

  verify_done:
    timeout_seconds: 90
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, random, sys, time, urllib.request, uuid
      import yaml

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      run = uuid.uuid4().hex[:10]
      r = random.Random()
      good, bad = [], []
      for i in range(12):
          m = r.choice(["GET", "POST", "PUT", "DELETE"])
          p = r.choice(["/cart", "/payments/charge", f"/orders/{r.randrange(10**5)}", "/search?q=socks&page=2"])
          s = r.choice([200, 201, 302, 404, 500, 503])
          good.append((f"check {run} good {i}", {"stringValue": f"{m} {p} {s}"}, (m, p, s)))
      bad = [(f"check {run} bad truncated", {"stringValue": "GET /search?q=bo"}),
             (f"check {run} bad missing", None),
             (f"check {run} bad number", {"intValue": "404"}),
             (f"check {run} bad empty", {"stringValue": ""})]
      def rec(body, value):
          return {"timeUnixNano": str(time.time_ns()), "body": {"stringValue": body},
                  "attributes": [] if value is None else [{"key": "request", "value": value}]}
      records = [rec(b, v) for b, v, _ in good] + [rec(b, v) for b, v in bad]
      r.shuffle(records)
      body = {"resourceLogs": [{"resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "edge-proxy"}}]},
          "scopeLogs": [{"logRecords": records}]}]}

      cfg = yaml.safe_load(open("/obs/otel/collector.yaml")) or {}
      procs = ((((cfg.get("service") or {}).get("pipelines") or {}).get("logs") or {}).get("processors")) or []

      req = urllib.request.Request("http://collector:4318/v1/logs", data=json.dumps(body).encode(),
                                   headers={"Content-Type": "application/json"})
      try:
          urllib.request.urlopen(req, timeout=10).read()
          refused = None
      except urllib.error.HTTPError as e:
          refused = (e.code, e.read().decode(errors="replace"))
      except OSError as e:
          no(f"nothing accepts OTLP/HTTP on collector:4318 ({getattr(e, 'reason', e)}).")

      def value(v):
          if "stringValue" in v: return v["stringValue"]
          if "intValue" in v: return int(v["intValue"])
          return next(iter(v.values()), None)
      out = {}
      for _ in range(20):
          time.sleep(0.5)
          try:
              lines = open("/obs/otel/out/access.jsonl").read().splitlines()
          except OSError:
              lines = []
          for l in lines:
              if run not in l:
                  continue
              for rl in json.loads(l).get("resourceLogs", []):
                  for sl in rl.get("scopeLogs", []):
                      for lr in sl.get("logRecords", []):
                          b = lr.get("body", {}).get("stringValue", "")
                          out[b] = {a["key"]: value(a["value"]) for a in lr.get("attributes", [])}
          if len(out) >= len(good):
              break

      if refused and not out:
          code, text = refused
          try:
              text = json.loads(text).get("message", text)
          except ValueError:
              pass
          reason = text.rsplit(": ", 1)[-1][:120]
          ttype = [p for p in procs if p.startswith("transform")]
          mode = ((cfg.get("processors") or {}).get(ttype[0]) or {}).get("error_mode", "propagate") if ttype else "?"
          late = [p for p in procs if p.startswith("filter") and ttype and procs.index(p) > procs.index(ttype[0])]
          why = [f"One record failed a statement ({reason}), and with error_mode: {mode} that fails",
                 "every record sent with it. The client retries the same batch and it fails again."]
          if late:
              why.append(f"{late[0]} would drop that record, and it runs after {ttype[0]}.")
          no(f"the Collector refused the whole batch ({code}): {len(records)} records, {len(good)} of them good.", *why)
      missing = [b for b, _, _ in good if b not in out]
      if missing:
          b = missing[0]
          v = next(v for bb, v, _ in good if bb == b)
          no(f"{len(missing)} of {len(good)} good records never reached the exporter, for example",
             f"  request = {v['stringValue']!r}",
             "Only malformed records may be dropped.")
      through = [b for b, _ in bad if b in out]
      if through:
          b = through[0]
          v = next(v for bb, v in bad if bb == b)
          no(f"{len(through)} malformed records went through to the exporter, for example the one with",
             f"  request = {('(no request attribute)' if v is None else json.dumps(v))}",
             f"  which came out with attributes {json.dumps(out[b])}",
             "A record that cannot be parsed has to be dropped, not passed on half-built.")
      want_keys = {"http.request.method", "url.path", "http.response.status_code"}
      for b, v, (m, p, s) in good:
          got = out[b]
          extra = sorted(set(got) - want_keys)
          lacking = sorted(want_keys - set(got))
          if lacking:
              no(f"a record for {v['stringValue']!r} came out with attributes {sorted(got)}.",
                 f"It lacks {', '.join(lacking)}. The target schema is http.request.method,",
                 "url.path and http.response.status_code.")
          if extra:
              hint = ["request is the field the three were made from."] if "request" in extra else []
              no(f"a record for {v['stringValue']!r} came out with {', '.join(extra)} as well as the three",
                 "target attributes. One field becomes three, and nothing else is left behind.", *hint)
          if got["http.response.status_code"] != s or not isinstance(got["http.response.status_code"], int):
              no(f"http.response.status_code is {got['http.response.status_code']!r} for {v['stringValue']!r}.",
                 "The schema says an integer, so that status_code >= 500 is a comparison and not a",
                 "string match. OTTL has Int().")
          if got["http.request.method"] != m or got["url.path"] != p:
              no(f"{v['stringValue']!r} came out as method {got['http.request.method']!r}, path {got['url.path']!r}.")
      print(f"PASS — {len(good)} good records reshaped to the schema and {len(bad)} malformed ones dropped,")
      print("in one batch, without losing the good ones.")
      PY
