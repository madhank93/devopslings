---
kind: lesson
title: "No query is slow and the order page takes a third of a second"
description: |
  A customer with a big order says the order page crawls. Every database
  call in its trace finishes in about a millisecond, and the database team
  says nothing is slow on their side. Read the trace, name what repeats, and
  make the page fast for an order of any size.
name: n-plus-one-from-a-trace
slug: n-plus-one-from-a-trace
createdAt: "2026-11-23"

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
      ticket=$(python3 - <<'PY'
      import os, random, sqlite3
      os.makedirs("/obs/data", exist_ok=True)
      path = "/obs/data/shop.db"
      if os.path.exists(path):
          os.remove(path)
      db = sqlite3.connect(path)
      db.executescript("""
          CREATE TABLE products (id INTEGER PRIMARY KEY, sku TEXT, name TEXT, price_cents INTEGER);
          CREATE TABLE orders (id INTEGER PRIMARY KEY, customer TEXT);
          CREATE TABLE order_items (id INTEGER PRIMARY KEY, order_id INTEGER, product_id INTEGER, qty INTEGER);
          CREATE INDEX order_items_order ON order_items (order_id);
      """)
      db.executemany("INSERT INTO products VALUES (?, ?, ?, ?)",
                     [(i, f"SKU-{i:05d}", f"product {i}", random.randint(199, 99999)) for i in range(1, 3001)])
      sizes = [random.randint(2, 30) for _ in range(34)] + [random.randint(120, 230) for _ in range(6)]
      random.shuffle(sizes)
      item = 0
      for n, size in enumerate(sizes, start=5101):
          db.execute("INSERT INTO orders VALUES (?, ?)", (n, f"customer-{random.randint(1, 900)}"))
          for p in random.sample(range(1, 3001), size):
              item += 1
              db.execute("INSERT INTO order_items VALUES (?, ?, ?, ?)", (item, n, p, random.randint(1, 4)))
      db.commit()
      print(5101 + sizes.index(max(sizes)))
      PY
      )
      echo "$ticket" > /obs/data/ticket
      cat > /obs/apps/shopdb.py <<'DRIVER'
      """shopdb — the client for the shop database, which runs on another host:
      every statement is a round trip that costs about a millisecond on the
      network, whatever the query. Part of the environment, not of checkout.
      While /obs/run/shopdb.count exists, each statement appends its trace id
      there: the database's own count of the queries a request made.
      """
      import os
      import sqlite3
      import time

      from opentelemetry import trace

      COUNT = "/obs/run/shopdb.count"


      class Cursor(sqlite3.Cursor):
          def execute(self, *args):
              time.sleep(0.001)
              if os.path.exists(COUNT):
                  with open(COUNT, "a") as f:
                      f.write(f"{trace.get_current_span().get_span_context().trace_id:032x}\n")
              return super().execute(*args)


      class Connection(sqlite3.Connection):
          def cursor(self, factory=Cursor):
              return super().cursor(factory)

          def execute(self, *args):
              return self.cursor().execute(*args)


      def connect():
          return sqlite3.connect("file:/obs/data/shop.db?mode=ro", uri=True, factory=Connection)
      DRIVER
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — the order page API on :8080. GET /orders/<id> returns the
      order with every line item. Data lives in the shop database.
      Some customers browsing their orders are simulated in-process.
      """
      import json
      import random
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      import shopdb

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"),
          schedule_delay_millis=500, max_queue_size=50000))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")
      local = threading.local()


      def query(sql, args=()):
          """One round trip to the shop database, as a CLIENT span named after
          the operation and table."""
          if not hasattr(local, "db"):
              local.db = shopdb.connect()
          words = sql.split()
          table = words[words.index("FROM") + 1] if "FROM" in words else "?"
          with tracer.start_as_current_span(f"{words[0]} shop.{table}", kind=trace.SpanKind.CLIENT) as span:
              span.set_attribute("db.system.name", "sqlite")
              span.set_attribute("db.namespace", "shop")
              span.set_attribute("db.query.text", sql)
              return local.db.execute(sql, args).fetchall()


      def load_order(order_id):
          rows = query("SELECT id, customer FROM orders WHERE id = ?", (order_id,))
          if not rows:
              return None
          items = []
          for product_id, qty in query("SELECT product_id, qty FROM order_items WHERE order_id = ?", (order_id,)):
              sku, name, price = query("SELECT sku, name, price_cents FROM products WHERE id = ?", (product_id,))[0]
              items.append({"sku": sku, "name": name, "qty": qty, "price_cents": price})
          return {"id": rows[0][0], "customer": rows[0][1], "items": items}


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def reply(self, code, body):
              self.send_response(code)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              parts = self.path.split("?")[0].strip("/").split("/")
              if len(parts) != 2 or parts[0] != "orders" or not parts[1].isdigit():
                  return self.reply(404, b'{"error":"no such route"}')
              with tracer.start_as_current_span("GET /orders/{id}", context=propagate.extract(self.headers),
                                                kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("http.route", "/orders/{id}")
                  span.set_attribute("order.id", parts[1])
                  order = load_order(int(parts[1]))
                  span.set_attribute("http.response.status_code", 200 if order else 404)
              if order is None:
                  return self.reply(404, b'{"error":"no such order"}')
              self.reply(200, json.dumps(order).encode())


      def customers():
          while True:
              try:
                  urllib.request.urlopen(f"http://localhost:8080/orders/{random.randint(5101, 5140)}", timeout=5).read()
              except OSError:
                  pass
              time.sleep(random.uniform(0.3, 0.6))


      threading.Thread(target=customers, daemon=True).start()
      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/answers/n-plus-one.txt <<TXT
      # Order $ticket's page is the one the customer complained about.
      # Read it from its trace. '#' starts a comment.
      span: ?    # the name of the span that repeats in that request
      count: ?   # how many times it appears in one request for order $ticket
      TXT
      for a in checkout; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: checkout serves GET /orders/<id> for orders 5101-5140 from the shop database."
      echo "The customer's ticket: order $ticket's page is slow. Time it:"
      echo "  curl -s -o /dev/null -w '%{time_total}s\\n' http://checkout:8080/orders/$ticket"
      echo "Its traces in Tempo:"
      echo "  curl -s 'http://tempo:3200/api/search?q={span.order.id=\"$ticket\"}&limit=5' | jq '.traces[].traceID'"
      echo "Your answer: /obs/answers/n-plus-one.txt. Source: /obs/apps/checkout.py (shopdb.py is the"
      echo "database client: the network to the database, not part of the fix)."

  verify_done:
    timeout_seconds: 150
    run: |
      # shopdb stands for the network to the database and counts the queries
      # the check grades, so the check puts back the lesson's copy (identical
      # to the one init writes) before it restarts checkout.
      cat > /obs/apps/shopdb.py <<'DRIVER'
      """shopdb — the client for the shop database, which runs on another host:
      every statement is a round trip that costs about a millisecond on the
      network, whatever the query. Part of the environment, not of checkout.
      While /obs/run/shopdb.count exists, each statement appends its trace id
      there: the database's own count of the queries a request made.
      """
      import os
      import sqlite3
      import time

      from opentelemetry import trace

      COUNT = "/obs/run/shopdb.count"


      class Cursor(sqlite3.Cursor):
          def execute(self, *args):
              time.sleep(0.001)
              if os.path.exists(COUNT):
                  with open(COUNT, "a") as f:
                      f.write(f"{trace.get_current_span().get_span_context().trace_id:032x}\n")
              return super().execute(*args)


      class Connection(sqlite3.Connection):
          def cursor(self, factory=Cursor):
              return super().cursor(factory)

          def execute(self, *args):
              return self.cursor().execute(*args)


      def connect():
          return sqlite3.connect("file:/obs/data/shop.db?mode=ro", uri=True, factory=Connection)
      DRIVER
      python3 - <<'PY'
      import json, os, re, sqlite3, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      ANSWER = "/obs/answers/n-plus-one.txt"
      BUDGET_MS = 80

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def tail(app):
          try:
              return ["  " + l.rstrip()[:200] for l in open(f"/obs/logs/{app}.log").readlines()[-3:]]
          except OSError:
              return []

      try:
          ticket = int(open("/obs/data/ticket").read())
          db = sqlite3.connect("file:/obs/data/shop.db?mode=ro", uri=True)
          sizes = dict(db.execute("SELECT order_id, count(*) FROM order_items GROUP BY order_id"))
      except (OSError, ValueError, sqlite3.Error) as e:
          no(f"the lesson's data in /obs/data is gone ({e}). Reset the lesson.")
      k = sizes[ticket]

      def field(name):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{name}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""

      span = field("span").strip("'\"`")
      count = field("count")
      if not span or span == "?":
          no(f"span in {ANSWER} is not filled in.")
      if span.lower() != "select shop.products":
          if span.lower() == "select shop.order_items":
              no(f"span is '{span}'. That query runs once per request; which span appears once per line",
                 "item?")
          if span.lower() in ("select shop.orders", "get /orders/{id}"):
              no(f"span is '{span}', which appears once in the request. Which span repeats?")
          no(f"span is '{span}', and no span of that name repeats in order {ticket}'s trace. Write the span",
             "name as Tempo shows it.")
      if not count.isdigit():
          no(f"count in {ANSWER} is '{count}'; write a whole number.")
      if int(count) != k:
          if int(count) in (k + 1, k + 2):
              no(f"count is {count}. That counts every database span in the request; how many are",
                 f"'{span}'?")
          no(f"count is {count}. Count the '{span}' spans in one request for order {ticket}.")

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # Every query has to cross shopdb, the only path to the database host.
      # Scan checkout and the modules of /obs/apps it imports for a way around it.
      src = {}
      todo = ["checkout"]
      while todo:
          name = todo.pop()
          try:
              src[name] = open(f"/obs/apps/{name}.py").read()
          except OSError:
              continue
          for m in re.finditer(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", src[name], re.M):
              if m.group(1) not in src and m.group(1) != "shopdb":
                  todo.append(m.group(1))
      for name, text in src.items():
          if re.search(r"\bsqlite3\b|shop\.db\b", text):
              no(f"/obs/apps/{name}.py opens the shop database itself (sqlite3 / shop.db) instead of through",
                 "shopdb.connect(). shopdb is the network to the database host: a connection that skips it",
                 "skips the round trips the real page pays and the query count the check grades.")

      # A fresh start empties any in-process cache.
      open("/obs/run/checkout.restart", "w").close()
      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      time.sleep(max(0, started("checkout") + 3 - time.time()))

      def fetch(order, tid=None):
          headers = {"traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"} if tid else {}
          t0 = time.monotonic()
          try:
              with urllib.request.urlopen(urllib.request.Request(
                      f"http://checkout:8080/orders/{order}", headers=headers), timeout=10) as r:
                  body = json.load(r)
          except (OSError, ValueError) as e:
              no(f"GET /orders/{order} failed ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))
          if len(body.get("items", [])) != sizes[order]:
              no(f"GET /orders/{order} returned {len(body.get('items', []))} items; the order has {sizes[order]}.",
                 "The page has to list every line item.")
          return (time.monotonic() - t0) * 1000, body

      by_size = sorted(sizes, key=sizes.get)
      sample = [by_size[0], by_size[len(by_size) // 3], by_size[2 * len(by_size) // 3], by_size[-2], by_size[-1]]
      traced = {o: os.urandom(16).hex() for o in sample}
      COUNT = "/obs/run/shopdb.count"
      open(COUNT, "w").close()
      try:
          for o, tid in traced.items():
              fetch(o, tid)
          logged = open(COUNT).read().split()
      finally:
          os.remove(COUNT)
      queries = {o: logged.count(tid) for o, tid in traced.items()}

      def db_spans(tid):
          deadline = time.time() + 20
          while True:
              try:
                  with urllib.request.urlopen(f"{TEMPO}/api/traces/{tid}", timeout=10) as r:
                      t = json.load(r)
                  spans = [s for b in t.get("batches", []) for ss in b.get("scopeSpans", []) for s in ss.get("spans", [])]
                  if any(s.get("kind") in ("SPAN_KIND_SERVER", 2) for s in spans):
                      return [s for s in spans if s.get("kind") in ("SPAN_KIND_CLIENT", 3)]
              except urllib.error.HTTPError as e:
                  if e.code != 404:
                      no(f"Tempo answered {e.code} for trace {tid}.")
              except OSError as e:
                  no(f"Tempo did not answer ({e}).")
              if time.time() > deadline:
                  no(f"Tempo has no server span of checkout for trace {tid} after 20s. checkout has to",
                     "continue the traceparent it receives and keep sending spans.")
              time.sleep(2)

      counts = {o: len(db_spans(tid)) for o, tid in traced.items()}
      desc = ", ".join(f"{sizes[o]} items: {queries[o]} queries/{counts[o]} spans" for o in sample)
      if min(queries.values()) == 0:
          no(f"some of the check's requests made no query through shopdb ({desc}). Every order page",
             "has to come from the shop database through shopdb.connect(); a cache or a connection of",
             "your own hides the queries instead of fixing them.")
      if any(queries[a] > queries[b] for a, b in zip(sample, sample[1:])):
          no(f"a bigger order made fewer queries than a smaller one ({desc}): a cache answers",
             "some lines and the database the rest. Every order page has to come from the database;",
             "fetch the lines and their products in one query.")
      if max(queries.values()) != min(queries.values()):
          if max(counts.values()) == min(counts.values()):
              no(f"queries per request still grow with the order ({desc}), but the database spans do",
                 "not: those queries run outside query(), untraced. The N+1 is still there; the trace",
                 "just stopped showing it.")
          no(f"queries per request still grow with the order ({desc}). One query per line item is",
             "still there.")
      if max(queries.values()) > 3:
          no(f"every request makes {max(queries.values())} queries ({desc}). It no longer grows, but an",
             "order page needs at most three.")
      if counts != queries:
          no(f"the database saw more queries than the trace shows ({desc}). Run every query through",
             "query(), so the trace shows it.")

      # A cache filled at startup draws no queries in a request; a price
      # changed after the restart shows whether the page reads the database.
      pid, old = db.execute("SELECT p.id, p.price_cents FROM order_items i JOIN products p ON p.id = i.product_id"
                            " WHERE i.order_id = ? LIMIT 1", (ticket,)).fetchone()
      rw = sqlite3.connect("/obs/data/shop.db", timeout=10)
      rw.execute("UPDATE products SET price_cents = ? WHERE id = ?", (old + 1, pid))
      rw.commit()
      try:
          _, body = fetch(ticket)
      finally:
          rw.execute("UPDATE products SET price_cents = ? WHERE id = ?", (old, pid))
          rw.commit()
      sku = f"SKU-{pid:05d}"
      shown = [i.get("price_cents") for i in body["items"] if i.get("sku") == sku]
      if shown != [old + 1]:
          no(f"order {ticket}'s page shows {sku} at {shown} cents after its price changed to {old + 1} in",
             "the database: the page comes from a copy loaded earlier, not from the database.")

      big = by_size[-5:]
      times = sorted(fetch(big[i % 5])[0] for i in range(40))
      p95 = times[int(len(times) * 0.95) - 1]
      if p95 > BUDGET_MS:
          no(f"p95 over 40 requests for the five biggest orders is {p95:.0f}ms; the budget is {BUDGET_MS}ms.",
             f"Per request: {desc}.")
      print(f"PASS — '{span}' ran {k} times for order {ticket}. Now every order page takes {counts[sample[0]]}")
      print(f"database round trips whatever its size, and p95 for the biggest orders is {p95:.0f}ms.")
      PY
---
