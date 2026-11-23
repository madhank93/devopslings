---
kind: lesson
title: "Agent, gateway, or both"
description: |
  A fleet of 300 hosts is moving to the OpenTelemetry Collector, and the
  design review is tomorrow. Tail sampling, redaction of card numbers,
  batching and retry each have to live somewhere: on every host, in a
  gateway tier, or both. Write the two configs and the reasons, and have the
  configs say what the reasons claim.
name: agent-versus-gateway
slug: agent-versus-gateway
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
      rm -rf /obs/fleet
      mkdir -p /obs/fleet
      cat > /obs/fleet/FLEET.md <<'MD'
      # The fleet

      - 300 hosts in three zones. Every host runs five to eight services. A
        checkout request crosses four to nine services on different hosts, so
        the spans of one trace are produced all over the fleet.
      - The payments and accounts services put `payment.card_number` and
        `user.email` on their spans. Compliance: neither may leave the host
        that produced it in clear text. The hosts are inside the PCI segment;
        nothing else in this design is.
      - The gateway tier is three Collectors, `gateway-1.obs.internal`,
        `gateway-2.obs.internal` and `gateway-3.obs.internal`, port 4317 (OTLP
        gRPC), in the shared observability cluster. A load balancer in front of
        them answers as `gateway.obs.internal:4317` and spreads connections
        across the three.
      - The backend is the vendor's OTLP intake, `otlp.vendor.example:4317`. It
        has had outages of up to ten minutes, about once a month.
      - Storage budget: every trace with an error, and 5% of the rest.
      - Applications send OTLP to `localhost:4317` and will not be changed.
      MD
      for f in agent gateway; do
        cat > /obs/fleet/$f.yaml <<'YML'
      # Collector config. Check it with: otelcol-contrib validate --config <this file>
      YML
      done
      cat > /obs/answers/topology.txt <<'TXT'
      # Where each job runs, and why. Each line: <agent|gateway|both> — <the reason>.
      tail_sampling: ?
      redaction: ?
      batching: ?
      retry: ?
      TXT
      echo "scenario ready: the fleet is described in /obs/fleet/FLEET.md."
      echo "Write /obs/fleet/agent.yaml (one per host) and /obs/fleet/gateway.yaml (one per gateway),"
      echo "and /obs/answers/topology.txt. otelcol-contrib is on the PATH to validate them."

  verify_done:
    timeout_seconds: 90
    run: |
      python3 - <<'PY'
      import re, subprocess, sys
      import yaml

      ANSWER = "/obs/answers/topology.txt"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def load(name):
          p = f"/obs/fleet/{name}.yaml"
          try:
              c = yaml.safe_load(open(p)) or {}
          except OSError:
              no(f"{p} is missing.")
          except yaml.YAMLError as e:
              no(f"{p} is not valid YAML: {str(e).splitlines()[0]}")
          if not isinstance(c, dict) or not c.get("service"):
              no(f"{p} has no Collector config in it yet.")
          r = subprocess.run(["otelcol-contrib", "validate", f"--config={p}"], capture_output=True, text=True)
          if r.returncode != 0:
              err = [l for l in (r.stderr + r.stdout).splitlines() if l.strip()][-1:]
              no(f"otelcol-contrib refuses {p}:", *["  " + l[:300] for l in err])
          return c

      def traces(c):
          procs, exps = [], []
          for name, p in (c.get("service", {}).get("pipelines") or {}).items():
              if name.split("/")[0] == "traces":
                  procs += p.get("processors") or []
                  exps += p.get("exporters") or []
          return procs, exps

      def kind(cid):
          return cid.split("/")[0]

      agent, gw = load("agent"), load("gateway")
      ap, ae = traces(agent)
      gp, ge = traces(gw)
      if not ae or not ge:
          no("each config needs a traces pipeline with an exporter.")

      # Tail sampling: in the gateway, with every span of a trace reaching the same gateway.
      if any(kind(p) == "tail_sampling" for p in ap):
          no("agent.yaml tail-samples. Each agent sees the spans its own host produced, and a trace",
             "crosses four to nine hosts: every agent would decide on a fragment of it.")
      if not any(kind(p) == "tail_sampling" for p in gp):
          no("gateway.yaml has no tail_sampling processor in its traces pipeline. The budget is every",
             "error trace and 5% of the rest, and only a tail sampler can know a trace had an error.")
      lb = [e for e in ae if kind(e) == "loadbalancing"]
      if not lb:
          hosts = " ".join(str((agent.get("exporters") or {}).get(e)) for e in ae)
          if "gateway.obs.internal" in hosts:
              no("the agents export to gateway.obs.internal, the load balancer. It spreads connections",
                 "across the three gateways, so one trace's spans land on all three and each gateway",
                 "tail-samples a fragment. The spans have to be routed by trace ID.")
          no("the agents do not route spans to the gateways by trace ID. With three gateways, every",
             "span of a trace has to reach the same one for tail sampling to see the whole trace.")
      cfg = (agent.get("exporters") or {}).get(lb[0]) or {}
      if cfg.get("routing_key", "traceID") != "traceID":
          no(f"the agents' loadbalancing exporter routes by {cfg.get('routing_key')}. Tail sampling needs",
             "every span of a trace on one gateway: route by traceID.")
      static = str(((cfg.get("resolver") or {}).get("static") or {}).get("hostnames"))
      want = [f"gateway-{i}.obs.internal" for i in (1, 2, 3)]
      if not all(h in static for h in want) and "dns" not in (cfg.get("resolver") or {}):
          no("the agents' loadbalancing exporter does not list the three gateways",
             f"({', '.join(want)}). Routing through the load balancer's name puts every trace on",
             "whichever gateway the connection landed on.")

      # Redaction: on the host, before anything leaves the PCI segment.
      def mentions(c, procs, *keys):
          text = " ".join(yaml.safe_dump((c.get("processors") or {}).get(p)) for p in procs
                          if kind(p) in ("attributes", "redaction", "transform"))
          return all(k in text for k in keys)
      if not mentions(agent, ap, "card_number", "email"):
          if mentions(gw, gp, "card_number", "email"):
              no("the gateway removes payment.card_number and user.email. The gateways run outside the PCI",
                 "segment, so the card numbers have already left it by the time they are removed.")
          no("agent.yaml does not remove or hash payment.card_number and user.email in its traces",
             "pipeline (an attributes, redaction or transform processor that names both).")

      # Batching in both tiers.
      for name, procs in (("agent.yaml", ap), ("gateway.yaml", gp)):
          if not any(kind(p) == "batch" for p in procs):
              no(f"{name} has no batch processor in its traces pipeline. Each tier makes its own exports,",
                 "and unbatched, each span is its own request.")

      # Retry: the gateway has to ride out the vendor's outages.
      def seconds(v):
          m = re.fullmatch(r"(\d+)(ms|s|m|h)", str(v).strip())
          return int(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[m.group(2)] if m else None
      vendor = [e for e in ge if "otlp.vendor.example" in str((gw.get("exporters") or {}).get(e))]
      if not vendor:
          no("gateway.yaml does not export to the vendor, otlp.vendor.example:4317.")
      v = (gw.get("exporters") or {}).get(vendor[0]) or {}
      r = v.get("retry_on_failure") or {}
      if r.get("enabled") is False or (v.get("sending_queue") or {}).get("enabled") is False:
          no(f"the gateway's {vendor[0]} exporter has retry or its queue turned off: the first vendor",
             "outage drops everything sent during it.")
      t = seconds(r.get("max_elapsed_time", "300s"))
      if t is not None and 0 < t < 600:
          no(f"the gateway's {vendor[0]} exporter gives up after {r.get('max_elapsed_time', '300s (the default)')}.",
             "The vendor's outages last up to ten minutes; data queued at the start of one is dropped",
             "before the vendor is back.")

      # The reasons.
      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return m.group(1).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""
      rules = {
          "tail_sampling": ({"gateway"}, r"\b(whole|complete|entire|all (the |of the )?spans|every span|trace ?id|fragments?)\b",
                            "that a sampling decision needs every span of the trace"),
          "redaction": ({"agent", "both"}, r"\b(pci|trust boundary|segment|leaves?|leaving|before|in clear|host)\b",
                        "where the data must not go before it is redacted"),
          "batching": ({"both"}, r"\b(fewer|requests?|round[- ]trips?|throughput|overhead|compression|efficien\w*|per[- ]span)\b",
                       "what batching saves on each hop"),
          "retry": ({"both", "gateway"}, r"\b(outages?|down|unavailable|restarts?|lose|loss|lost|drop\w*|queue\w*)\b",
                    "what a retry protects against"),
      }
      for k, (tiers, why, what) in rules.items():
          v = field(k)
          if not v or v == "?":
              no(f"{k} in {ANSWER} is not filled in.")
          m = re.match(r"\s*(agent|gateway|both)\b", v.lower())
          if not m:
              no(f"{k} is '{v}'. Start it with agent, gateway or both.")
          if m.group(1) not in tiers:
              no(f"{k} says {m.group(1)}, and your configs say otherwise; which tier does it run in,",
                 "and what does that tier see?")
          rest = v.lower()[m.end():]
          if len(rest.split()) < 5 or not re.search(why, rest):
              no(f"{k}'s reason, '{rest.strip(' -—:')}', does not say {what}.")
      print("PASS — agents redact and batch on the host and route by trace ID to the three gateways;")
      print("gateways tail-sample whole traces, batch, and retry through a ten-minute vendor outage.")
      PY
---
