---
kind: lesson
title: "five times the CPU in production as in the load test"
description: |
  The pricing API runs hot in production and idles in the load test, on the
  same build. Reproducing it locally has failed twice. Production has been
  sending a continuous profile to Pyroscope all along: read the hot function
  out of it, find what production sends that the load test never does, and
  make it cheaper.
name: profile-in-production
slug: profile-in-production
createdAt: "2026-11-22"
timingSensitive: true

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
      rm -rf /obs/pricing /obs/run/pricing.* /obs/logs/pricing.log
      mkdir -p /obs/pricing

      cat > /obs/pricing/pricing.py <<'PY'
      """Order pricing. The API calls price_order() once per order."""
      from decimal import Decimal, ROUND_HALF_UP

      CENT = Decimal("0.01")
      TAX = {"EU": Decimal("0.20"), "UK": Decimal("0.20"), "US": Decimal("0.07")}
      CODES = {"SPRING10": Decimal("0.10"), "BULK5": Decimal("0.05")}


      def normalize_lines(lines):
          """Merge lines that repeat a SKU, keeping first-seen order."""
          merged = []
          for line in lines:
              for m in merged:
                  if m["sku"] == line["sku"]:
                      m["qty"] += line["qty"]
                      break
              else:
                  merged.append({"sku": line["sku"], "qty": line["qty"], "unit": line["unit"]})
          return merged


      def subtotal(lines):
          return sum((Decimal(l["unit"]) * l["qty"] for l in lines), Decimal(0))


      def apply_discounts(amount, codes):
          for code in codes:
              rate = CODES.get(code)
              if rate is not None:
                  amount -= (amount * rate).quantize(CENT, ROUND_HALF_UP)
          return amount


      def apply_tax(amount, region):
          return (amount * (1 + TAX[region])).quantize(CENT, ROUND_HALF_UP)


      def price_order(order):
          lines = normalize_lines(order["lines"])
          amount = apply_discounts(subtotal(lines), order["codes"])
          return {"order": order["id"], "lines": len(lines), "total": str(apply_tax(amount, order["region"]))}
      PY
      cat > /obs/pricing/orders.py <<'PY'
      """Order shapes seen in production. Most tenants send a handful of lines;
      acme's procurement system sends whole catalogue reorders."""


      def make_order(rng, seq, shape):
          n = rng.randint(1500, 2500) if shape == "bulk" else rng.randint(2, 8)
          skus = 4000 if shape == "bulk" else 50
          return {
              "id": f"{'acme' if shape == 'bulk' else 'web'}-{seq}",
              "region": rng.choice(["EU", "UK", "US"]),
              "codes": rng.sample(["SPRING10", "BULK5", "NOPE"], rng.randint(0, 2)),
              "lines": [{"sku": f"SKU-{rng.randrange(skus):05d}", "qty": rng.randint(1, 4),
                         "unit": f"{rng.randint(100, 99999) / 100:.2f}"} for _ in range(n)],
          }
      PY
      cat > /obs/pricing/production.py <<'PY'
      """production.py PRICING_PY — the pricing API under production traffic,
      continuously profiled to Pyroscope as service "pricing"."""
      import importlib.util, os, random, sys, time
      import pyroscope

      sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
      from orders import make_order

      pyroscope.configure(application_name="pricing", server_address=os.environ.get("PYROSCOPE", "http://pyroscope:4040"),
                          sample_rate=100, tags={"env": "production"})
      spec = importlib.util.spec_from_file_location("pricing", sys.argv[1])
      pricing = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(pricing)

      rng, seq = random.Random(), 0
      while True:
          start = time.monotonic()
          for i in range(8000):
              seq += 1
              pricing.price_order(make_order(rng, seq, "bulk" if i % 1000 == 0 else "small"))
          time.sleep(max(0.0, 1 - (time.monotonic() - start)))
      PY
      cat > /obs/pricing/loadtest.py <<'PY'
      """loadtest.py — the pre-release load test: ten seconds of typical orders
      against /obs/pricing/pricing.py, then the CPU it used."""
      import os, random, sys, time
      sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
      import pricing
      from orders import make_order

      rng, n, t0, c0 = random.Random(7), 0, time.monotonic(), time.process_time()
      while time.monotonic() - t0 < 10:
          for _ in range(8000):
              n += 1
              pricing.price_order(make_order(rng, n, "small"))
          time.sleep(max(0.0, n / 8000 - (time.monotonic() - t0)))
      print(f"{n} orders in {time.monotonic() - t0:.1f} s, {100 * (time.process_time() - c0) / (time.monotonic() - t0):.0f}% of a CPU")
      PY
      cat > /obs/pricing/replay.py <<'PY'
      """replay.py PRICING_PY — price a fixed sample of production traffic and print
      the results' digest and the CPU seconds it took."""
      import hashlib, importlib.util, json, random, sys, time
      sys.path.insert(0, "/obs/pricing")
      from orders import make_order

      spec = importlib.util.spec_from_file_location("pricing_under_test", sys.argv[1])
      pricing = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(pricing)
      rng = random.Random(20261122)
      orders = [make_order(rng, i, "bulk" if i % 40 == 0 else "small") for i in range(400)]
      t0 = time.process_time()
      out = [pricing.price_order(o) for o in orders]
      cpu = time.process_time() - t0
      # Merged lines keep first-seen order: callers display them as the customer sent them.
      out.append([[l["sku"] for l in pricing.normalize_lines(o["lines"])] for o in orders[::40]])
      print(json.dumps({"cpu_s": round(cpu, 3), "digest": hashlib.sha256(json.dumps(out).encode()).hexdigest()}))
      PY
      cp /obs/pricing/pricing.py /obs/run/pricing.orig.py
      (cd /obs/pricing && sha256sum replay.py orders.py) > /obs/run/pricing.sums
      chmod -R a+rX /obs/pricing

      for _ in $(seq 1 60); do curl -fs -m 2 "$PYROSCOPE/ready" >/dev/null 2>&1 && break; sleep 1; done
      setsid supervise pricing python3 /obs/pricing/production.py /obs/pricing/pricing.py \
        </dev/null >/dev/null 2>&1 &

      # The scenario is a profile, so wait until Pyroscope holds one.
      q='process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name="pricing"}'
      for _ in $(seq 1 90); do
        ticks=$(curl -s -m 5 -G "$PYROSCOPE/pyroscope/render" --data-urlencode "query=$q" \
                  --data-urlencode from=now-5m --data-urlencode until=now --data-urlencode format=json |
                jq -r '.flamebearer.numTicks // 0' 2>/dev/null || echo 0)
        [ "${ticks:-0}" != 0 ] && break
        sleep 2
      done
      if [ "${ticks:-0}" = 0 ]; then
        echo "scenario setup failed: no profile for service pricing reached Pyroscope" >&2
        tail -5 /obs/logs/pricing.log >&2 || true
        exit 1
      fi

      echo "scenario ready — the pricing API runs under production traffic and profiles itself to"
      echo "Pyroscope as service_name=\"pricing\": Grafana http://localhost:13000 (Explore, Pyroscope)"
      echo "or Pyroscope's own UI at http://localhost:14040. The code is /obs/pricing/pricing.py; the"
      echo "load test that stays cool is python3 /obs/pricing/loadtest.py."

  verify_done:
    timeout_seconds: 180
    run: |
      python3 - <<'PY'
      import json, subprocess, sys

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      ans = {}
      try:
          for line in open("/obs/answers/profile.txt"):
              if "=" in line:
                  k, v = line.split("=", 1)
                  ans[k.strip()] = v.strip().strip('"')
      except OSError:
          pass
      hot = ans.get("hot_function", "").split(".")[-1].split("(")[0].strip()
      if not hot:
          no("/obs/answers/profile.txt needs hot_function=<name>: the function that takes most of the",
             "CPU in the production profile in Pyroscope.")
      if hot in ("apply_tax", "apply_discounts", "subtotal", "quantize", "make_order"):
          no(f"hot_function={hot} is what the load test spends its time in. Production's profile is a",
             "different shape: open service_name=pricing in Pyroscope and read the widest frame there.")
      if hot in ("price_order", "<module>", "production", "main"):
          no(f"hot_function={hot} is in every sample: a frame's width includes everything it calls.",
             "Follow the widest child of price_order.")
      if hot != "normalize_lines":
          no(f"hot_function={hot}. Read the production profile (service_name=pricing) top-down from",
             "price_order and name its widest child.")

      if subprocess.run("cd /obs/pricing && sha256sum -c --quiet /obs/run/pricing.sums", shell=True,
                        capture_output=True).returncode != 0:
          no("/obs/pricing/replay.py or orders.py has changed. They are the production replay the check",
             "measures with; the fix belongs in pricing.py.")

      def replay(path):
          r = subprocess.run(["python3", "/obs/pricing/replay.py", path], capture_output=True, text=True, timeout=120)
          if r.returncode != 0:
              no(f"{path} fails on the production replay:", *r.stderr.strip().splitlines()[-3:])
          return json.loads(r.stdout.strip().splitlines()[-1])

      orig = [replay("/obs/run/pricing.orig.py") for _ in range(2)]
      mine = [replay("/obs/pricing/pricing.py") for _ in range(2)]
      if mine[0]["digest"] != orig[0]["digest"]:
          no("/obs/pricing/pricing.py prices the replayed orders differently from the original. Make",
             "merging cheaper; the merged lines, their order and every total have to stay the same.")
      before = min(r["cpu_s"] for r in orig)
      after = min(r["cpu_s"] for r in mine)
      print(f"this check replayed 400 production orders: original {before:.3f} s of CPU, yours {after:.3f} s")
      if after > 0.6 * before:
          no(f"the replay costs {after:.3f} s of CPU against {before:.3f} s; it needs to be at least 40% less.",
             "Profile pricing.py again: what is left in normalize_lines, and why does acme's order cost",
             "so much more than its length?")
      print(f"PASS — normalize_lines was the production hot path (quadratic in acme's bulk orders); the")
      print(f"       replay now costs {after:.3f} s of CPU against {before:.3f} s, with every price unchanged.")
      PY
---
