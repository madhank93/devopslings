---
kind: lesson
title: "Ten thousand errors, and how many bugs?"
description: |
  checkout just threw ten thousand exceptions, every one recorded on its
  span in Tempo, and the on-call is calling it an outage of everything.
  Every message is different, because every message has an ID in it. Group
  the events into the bugs that produced them, and rank the bugs.
name: exceptions-grouped
slug: exceptions-grouped
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
      g=/var/lib/devopslings/exceptions-grouped
      rm -rf "$g" /srv/checkout
      mkdir -p "$g" /srv/checkout
      cat > /srv/checkout/pricing.py <<'PY'
      PRICES = {f"sku-{i}": 100 + i for i in range(1000)}


      def lookup_price(sku):
          return PRICES[sku]
      PY
      cat > /srv/checkout/cart.py <<'PY'
      CARTS = {}


      def load_cart(cart_id):
          return CARTS[cart_id]
      PY
      cat > /srv/checkout/payments.py <<'PY'
      def charge(order_id, amount):
          raise TimeoutError(f"payment provider did not answer for order {order_id} ({amount}) after 2.0s")
      PY
      cat > /srv/checkout/inventory.py <<'PY'
      def reserve(sku, qty):
          raise TimeoutError(f"lock on {sku} not acquired within 500ms (qty {qty})")
      PY
      cat > /srv/checkout/orders.py <<'PY'
      def parse_quantity(raw):
          return int(raw)
      PY
      cat > /srv/checkout/app.py <<'PY'
      import random

      from opentelemetry import trace

      from cart import load_cart
      from inventory import reserve
      from orders import parse_quantity
      from payments import charge
      from pricing import lookup_price


      def sku():
          return f"sku-{random.randint(1000, 99999)}"


      def quote():
          return lookup_price(sku())


      def place_order(step):
          order = f"ord-{random.randint(10**6, 10**7)}"
          if step == "price":
              return lookup_price(sku())
          if step == "reserve":
              return reserve(sku(), random.randint(1, 9))
          return charge(order, f"{random.randint(5, 900)}.{random.randint(10, 99)} EUR")


      def restore_session():
          return load_cart(f"cart-{random.randint(10**5, 10**6)}")


      def add_to_cart():
          return parse_quantity(random.choice(["x", "1o", "two", "3 ", "#"]) + str(random.randint(1, 99)))


      PATHS = {
          "quote": ("GET /quote", quote),
          "price": ("POST /orders", lambda: place_order("price")),
          "reserve": ("POST /orders", lambda: place_order("reserve")),
          "charge": ("POST /orders", lambda: place_order("charge")),
          "cart": ("GET /cart", restore_session),
          "qty": ("POST /cart/items", add_to_cart),
          "ok": ("GET /cart", lambda: None),
      }


      def handle(tracer, path):
          name, fn = PATHS[path]
          with tracer.start_as_current_span(name, kind=trace.SpanKind.SERVER, record_exception=False,
                                            set_status_on_exception=False) as span:
              try:
                  fn()
              except Exception as e:
                  span.record_exception(e)
                  span.set_status(trace.StatusCode.ERROR, f"{type(e).__name__}: {e}")
      PY
      cat > "$g/incident.py" <<'PY'
      # incident.py TRUTH_FILE — replay the incident into Tempo and write how
      # many events each bug produced.
      import json, random, sys, time
      sys.path.insert(0, "/srv/checkout")
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      import app

      sizes = [4100, 2700, 1800, 900, 500]
      random.shuffle(sizes)
      bugs = ["KeyError|lookup_price", "KeyError|load_cart", "TimeoutError|charge",
              "TimeoutError|reserve", "ValueError|parse_quantity"]
      truth = {b: n + random.randint(-40, 40) for b, n in zip(bugs, sizes)}
      split = random.randint(truth["KeyError|lookup_price"] // 3, truth["KeyError|lookup_price"] * 2 // 3)
      plan = (["quote"] * split + ["price"] * (truth["KeyError|lookup_price"] - split)
              + ["cart"] * truth["KeyError|load_cart"] + ["charge"] * truth["TimeoutError|charge"]
              + ["reserve"] * truth["TimeoutError|reserve"] + ["qty"] * truth["ValueError|parse_quantity"]
              + ["ok"] * 3000)
      random.shuffle(plan)

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"),
          max_queue_size=len(plan) + 1, max_export_batch_size=500, schedule_delay_millis=200))
      tracer = provider.get_tracer("checkout")
      # Paced: Tempo refuses spans beyond 10,000 live traces at once.
      for i, p in enumerate(plan):
          app.handle(tracer, p)
          if i % 50 == 0:
              time.sleep(0.1)
      provider.shutdown()
      json.dump(truth, open(sys.argv[1], "w"))
      PY
      python3 "$g/incident.py" "$g/truth.json"
      cat > /obs/answers/issues.txt <<'TXT'
      # One line per distinct bug, the most events first:
      #   <exception.type> | <function the exception was raised in> | <number of events>
      # e.g.  ZeroDivisionError | apply_discount | 1234
      TXT
      sleep 5
      echo "scenario ready: checkout recorded $(python3 -c "import json; print(sum(json.load(open('$g/truth.json')).values()))") exceptions on its spans in the last minute,"
      echo "all in Tempo. Two of them:"
      echo "  curl -s -G http://tempo:3200/api/search --data-urlencode 'q={resource.service.name=\"checkout\" && status=error}' \\"
      echo "    --data-urlencode limit=2 | jq"
      echo "Your answer: /obs/answers/issues.txt"

  verify_done:
    timeout_seconds: 60
    run: |
      python3 - <<'PY'
      import json, re, sys

      TRUTH = "/var/lib/devopslings/exceptions-grouped/truth.json"
      ANSWER = "/obs/answers/issues.txt"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      try:
          truth = json.load(open(TRUTH))
      except (OSError, ValueError):
          no("the scenario's record of the incident is missing. Reset the lesson.")
      types = {b.split("|")[0] for b in truth}
      funcs = {b.split("|")[1] for b in truth}

      rows = []
      try:
          for n, line in enumerate(open(ANSWER), 1):
              line = line.split("#")[0].strip()
              if not line:
                  continue
              f = [x.strip() for x in line.split("|")]
              if len(f) != 3 or not re.fullmatch(r"\d+", f[2].replace(",", "")):
                  no(f"line {n} of {ANSWER} is '{line}'. Each line is",
                     "<exception.type> | <function it was raised in> | <number of events>.")
              rows.append((f[0], f[1], int(f[2].replace(",", ""))))
      except OSError:
          no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
      if not rows:
          no(f"{ANSWER} lists no bugs yet.")
      if len(rows) > 20:
          no(f"{ANSWER} lists {len(rows)} groups. Exception messages carry order IDs, SKUs and",
             "amounts, so grouping on the message, or on a stack trace that ends in it, makes",
             "nearly every event its own group.")

      counted = {}
      for t, fn, c in rows:
          if t not in types:
              no(f"'{t}' is not an exception.type checkout recorded. Use the type exactly as the",
                 "span event's exception.type attribute has it.")
          if not fn:
              no(f"'{t}' has no function. A type alone is not a bug: the same type can be raised in",
                 "different places for different reasons.")
          fn = fn if fn in funcs else fn.rsplit(".", 1)[-1].split("(")[0].strip()
          if fn not in funcs:
              no(f"'{fn}' is not the function any of checkout's exceptions was raised in. It is the",
                 "innermost frame of exception.stacktrace, the last 'File ..., in <function>' line.")
          if f"{t}|{fn}" not in truth:
              no(f"no {t} was raised in {fn}. Read the type and the frame from the same event.")
          if f"{t}|{fn}" in counted:
              no(f"{t} in {fn} is listed twice. Events raised at the same place by the same type",
                 "are one bug, whichever path called that function.")
          counted[f"{t}|{fn}"] = c

      if len(counted) < len(truth):
          for t in sorted(types):
              have = sum(1 for b in counted if b.startswith(t + "|"))
              want = sum(1 for b in truth if b.startswith(t + "|"))
              if have < want:
                  no(f"{ANSWER} lists {len(counted)} bugs. {t} was raised in {want} different functions and",
                     f"your answer has {have}: grouping on the type alone merges unrelated bugs.")
      for b, n in truth.items():
          c = counted[b]
          if abs(c - n) > n * 0.03:
              t, fn = b.split("|")
              no(f"{t} in {fn}: your count, {c}, is more than 3% from the number of events Tempo",
                 "holds for it. A search returns 20 traces unless you ask for more (limit=), and one",
                 "span per trace unless you ask for more (spss=).")
      ranked = list(counted)
      if ranked != sorted(truth, key=truth.get, reverse=True):
          no("the bugs are not in order of event count, most first. The ranking is what the on-call",
             "works down.")
      print(f"PASS — {sum(truth.values())} events are {len(truth)} bugs, ranked by event count:")
      for b in ranked:
          print(f"  {truth[b]:5d}  {b.replace('|', ' in ')}")
      PY
---
