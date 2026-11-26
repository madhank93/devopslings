---
kind: lesson
title: "Every team instruments differently"
description: |
  Three services, three ideas of what a span should say: one sends
  httpStatus, one sends no version, one has no environment at all, and no
  dashboard works across them. Write the instrumentation standard, name who
  owns the shared instrumentation, and build the review gate that fails a
  service which does not follow it.
name: instrumentation-standard
slug: instrumentation-standard
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
      g=/var/lib/devopslings/instrumentation-standard
      rm -rf /obs/standard "$g"
      mkdir -p /obs/standard/samples "$g"
      cat > "$g/otlp.py" <<'PY'
      # otlp.py — write a one-trace OTLP/JSON export. Span kind 2 is SERVER, 3 is CLIENT.
      import json, os, sys

      def val(v):
          return {"intValue": str(v)} if isinstance(v, int) else {"stringValue": str(v)}

      def attrs(d):
          return [{"key": k, "value": val(v)} for k, v in d.items()]

      def export(path, resource, spans):
          tid = os.urandom(16).hex()
          out = []
          for name, kind, a in spans:
              out.append({"traceId": tid, "spanId": os.urandom(8).hex(), "name": name, "kind": kind,
                          "startTimeUnixNano": "1795390000000000000", "endTimeUnixNano": "1795390000030000000",
                          "attributes": attrs(a)})
          json.dump({"resourceSpans": [{"resource": {"attributes": attrs(resource)},
                                        "scopeSpans": [{"scope": {"name": "app"}, "spans": out}]}]},
                    open(path, "w"), indent=1)
      PY
      python3 - <<'PY'
      import sys
      sys.path.insert(0, "/var/lib/devopslings/instrumentation-standard")
      from otlp import export
      d = "/obs/standard/samples"
      export(f"{d}/checkout.json",
             {"service.name": "checkout", "service.version": "4.12.0", "env": "prod"},
             [("POST /checkout", 2, {"http.method": "POST", "url": "/checkout?cart=88213", "httpStatus": 200}),
              ("POST", 3, {"http.method": "POST", "peer": "payments"})])
      export(f"{d}/search.json",
             {"service.name": "search", "deployment.environment.name": "production"},
             [("GET /search", 2, {"http.request.method": "GET", "http.route": "/search",
                                  "http.response.status_code": 200})])
      export(f"{d}/payments.json",
             {"service.name": "payments-svc", "service.version": "2025.11.3"},
             [("handle", 2, {"method": "POST", "path": "/charge/ord-77120", "status": "200"})])
      PY
      cat > /obs/standard/TEAMS.md <<'MD'
      # Teams

      checkout   owns checkout
      search     owns search
      payments   owns payments
      platform   maintains obs-lib, the shared Python package every service imports
                 to set up OpenTelemetry (exporter, resource, HTTP middleware), and
                 the CI pipeline every service's merge request runs through
      MD
      cat > /obs/standard/standard.yaml <<'YML'
      # The instrumentation standard. '?' marks what to fill in.
      semconv_version: "?"                  # the OpenTelemetry semantic conventions release it follows
      resource_attributes: []               # required on every service's resource
      server_span_attributes: []            # required on every SERVER span
      shared_instrumentation_owner: "?"     # the team that owns the shared instrumentation, from TEAMS.md
      YML
      cat > /obs/standard/gate <<'SH'
      #!/usr/bin/env bash
      # gate EXPORT.json — the review gate. Exit 0 when the service's OTLP/JSON
      # export meets /obs/standard/standard.yaml; otherwise print what is missing
      # and exit non-zero.
      exit 0
      SH
      chmod +x /obs/standard/gate
      echo "scenario ready: /obs/standard/samples holds one trace from each of three services."
      echo "Write /obs/standard/standard.yaml and make /obs/standard/gate enforce it:"
      echo "  /obs/standard/gate /obs/standard/samples/search.json; echo \$?"

  verify_done:
    timeout_seconds: 90
    run: |
      python3 - <<'PY'
      import os, re, shutil, subprocess, sys, tempfile
      import yaml
      sys.path.insert(0, "/var/lib/devopslings/instrumentation-standard")
      from otlp import export

      STD, GATE = "/obs/standard/standard.yaml", "/obs/standard/gate"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      try:
          std = yaml.safe_load(open(STD)) or {}
      except OSError:
          no(f"{STD} is missing. Reset the lesson to get the template back.")
      except yaml.YAMLError as e:
          no(f"{STD} is not valid YAML: {str(e).splitlines()[0]}")

      ver = str(std.get("semconv_version", "?"))
      if not re.fullmatch(r"v?\d+\.\d+(\.\d+)?", ver):
          no(f"semconv_version is '{ver}'. Name the semantic conventions release the standard follows,",
             "like 1.30.0: attribute names change between releases, and 'latest' moves.")
      res = [str(x) for x in std.get("resource_attributes") or []]
      srv = [str(x) for x in std.get("server_span_attributes") or []]
      adhoc = {"env", "url", "httpStatus", "status", "path", "method", "peer", "http.method", "http.status_code",
               "http.url", "http.target", "deployment.environment"}
      for k in res + srv:
          if k in adhoc:
              no(f"the standard requires '{k}', a name the current semantic conventions replaced or never",
                 "had. A standard that writes down today's mess keeps it.")
      for k in ("service.name", "service.version", "deployment.environment.name"):
          if k not in res:
              no(f"resource_attributes does not require {k}. Without it, spans cannot be told apart by",
                 {"service.name": "service", "service.version": "release, so a bad deploy cannot be seen",
                  "deployment.environment.name": "environment, so staging traffic lands in production's graphs"}[k] + ".")
      for k in ("http.request.method", "http.route", "http.response.status_code"):
          if k not in srv:
              no(f"server_span_attributes does not require {k}; per-route latency and error rates need",
                 "method, route template and status code on every server span.")
      owner = str(std.get("shared_instrumentation_owner", "?")).strip().lower()
      if owner in ("?", ""):
          no("shared_instrumentation_owner is not filled in.")
      if owner != "platform":
          if owner in ("checkout", "search", "payments"):
              no(f"shared_instrumentation_owner is {owner}. obs-lib is imported by every service; a product",
                 "team owning it means everyone else's instrumentation waits on that team's priorities.")
          no(f"shared_instrumentation_owner is '{owner}'. One team from TEAMS.md owns it; 'everyone'",
             "is how obs-lib ended up with three ideas of what a span should say.")

      if not os.access(GATE, os.X_OK):
          no(f"{GATE} is missing or not executable.")
      tmp = tempfile.mkdtemp()
      full = {"service.name": "orders", "service.version": "1.4.2", "deployment.environment.name": "production"}
      span = {"http.request.method": "GET", "http.route": "/orders/{id}", "http.response.status_code": 200}
      extra_res = {k: "x" for k in res if k not in full}
      extra_srv = {k: "x" for k in srv if k not in span}
      ok_res, ok_span = dict(full, **extra_res), dict(span, **extra_srv)
      cases = [
          ("good", ok_res, [("GET /orders/{id}", 2, ok_span), ("SELECT orders", 3, {"db.system.name": "postgresql"})], True,
           "a service that has every attribute the standard requires", None),
          ("client-only", ok_res, [("GET", 3, {"http.request.method": "GET", "server.address": "pricing"})], True,
           "a service whose only spans are CLIENT spans, with a complete resource. Route and status are required on SERVER spans", None),
          ("no-version", {k: v for k, v in ok_res.items() if k != "service.version"}, [("GET /orders/{id}", 2, ok_span)], False,
           "a service with no service.version", "service.version"),
          ("no-env", {k: v for k, v in ok_res.items() if k != "deployment.environment.name"}, [("GET /orders/{id}", 2, ok_span)], False,
           "a service with no deployment.environment.name", "deployment.environment.name"),
          ("adhoc", ok_res, [("GET /orders/8812", 2, dict({k: v for k, v in ok_span.items() if k not in ("http.route", "http.response.status_code")},
                                                       url="/orders/8812", httpStatus=200))], False,
           "a service that sends url and httpStatus instead of http.route and http.response.status_code", "http.route"),
          ("one-bad-span", ok_res, [("GET /orders/{id}", 2, ok_span),
                                    ("POST /orders", 2, {k: v for k, v in ok_span.items() if k != "http.route"})], False,
           "a service with one SERVER span, of two, missing http.route", "http.route"),
      ]

      def run(path):
          try:
              r = subprocess.run([GATE, path], capture_output=True, text=True, timeout=20)
          except subprocess.TimeoutExpired:
              no(f"{GATE} ran for 20s on one file. A review gate has to answer in seconds.")
          return r.returncode, r.stdout + r.stderr

      for name, resource, spans, want, what, key in cases:
          p = f"{tmp}/{name}.json"
          export(p, resource, spans)
          rc, out = run(p)
          if want and rc != 0:
              no(f"the gate fails {what}:", *["  " + l for l in out.strip().splitlines()[-3:]])
          if not want and rc == 0:
              no(f"the gate passes {what}. A standard nothing enforces is a suggestion.")
          if not want and key not in out:
              no(f"the gate fails {what}, and its output does not say {key} is missing. The",
                 "author of the merge request it blocks needs to know what to add.")

      # The gate has to read the standard, not a copy of it.
      saved = open(STD).read()
      try:
          d = yaml.safe_load(saved)
          d["resource_attributes"] = list(d.get("resource_attributes") or []) + ["service.namespace"]
          open(STD, "w").write(yaml.safe_dump(d, sort_keys=False))
          rc, _ = run(f"{tmp}/good.json")
      finally:
          open(STD, "w").write(saved)
      shutil.rmtree(tmp, ignore_errors=True)
      if rc == 0:
          no("with service.namespace added to resource_attributes, the gate still passes a service that",
             "does not have it. The gate has to read standard.yaml, or the two drift the first time",
             "someone edits one of them.")
      print("PASS — the standard names semconv attributes and an owner, and the gate enforces exactly it:")
      print("compliant and client-only services pass, every missing attribute fails with its name.")
      PY
---
