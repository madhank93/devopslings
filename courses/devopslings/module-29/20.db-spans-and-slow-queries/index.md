---
kind: lesson
title: "p99 is in the database, and the account page runs a dozen queries"
description: |
  The account page's p99 is all database time, and it runs a dozen queries
  per request. The one everybody suspects is the big join. Find the slow
  statement from the spans' db.query.text, match it in pg_stat_statements,
  and fix it in the database so that span gets fast.
name: db-spans-and-slow-queries
slug: db-spans-and-slow-queries
createdAt: "2026-11-22"

sandbox:
  stack: obs-stack
  with: [db-stack]
  service: box

tasks:
  init_scenario:
    init: true
    service: host
    timeout_seconds: 300
    run: |
      # db-stack's primary joins obs-stack's network as "pg". Joined this way
      # round, each stack's teardown removes only its own containers' links.
      net=devopslings-obs-stack_default
      pg=devopslings-db-stack-primary-1
      if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$pg" | grep -qw "$net"; then
        docker network connect --alias pg "$net" "$pg"
      fi
      docker exec "$pg" psql -U postgres -d shop -qc \
        "DO \$\$ DECLARE i text; BEGIN
           FOR i IN SELECT indexrelid::regclass::text FROM pg_index
                    WHERE indrelid = 'customers'::regclass AND NOT indisprimary LOOP
             EXECUTE 'DROP INDEX ' || i;
           END LOOP; END \$\$; SELECT pg_stat_statements_reset();" >/dev/null
      docker exec -i devopslings-obs-stack-box-1 bash -s <<'BOX'
      set -euo pipefail
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      g=/var/lib/devopslings/db-spans
      mkdir -p "$g"
      cat > /obs/apps/orders.py <<'PY'
      """orders — the account page. GET /account runs a dozen queries against
      the shop database (db-stack's primary, reachable here as pg:5432). Each
      query is a CLIENT span with the semantic-convention db attributes.
      Customers are simulated in-process."""
      import random, time

      import psycopg
      from opentelemetry import trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "orders"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("orders")

      PAGE = [
          ("SELECT id, email, country FROM customers WHERE id = %(cid)s", {}),
          ("SELECT count(*) FROM orders WHERE customer_id = %(cid)s", {}),
          ("SELECT id, status, total_cents, placed_at FROM orders WHERE customer_id = %(cid)s ORDER BY placed_at DESC LIMIT 10", {}),
          ("SELECT status, count(*) FROM orders WHERE customer_id = %(cid)s GROUP BY status", {}),
          ("SELECT c.country, count(o.id), sum(o.total_cents), max(o.placed_at) FROM customers c "
           "JOIN orders o ON o.customer_id = c.id "
           "WHERE c.id = %(cid)s AND o.status IN ('placed', 'picked', 'shipped') "
           "AND o.placed_at > now() - interval '365 days' "
           "GROUP BY c.country HAVING count(o.id) > 0 ORDER BY 3 DESC", {}),
          ("SELECT sum(total_cents) FROM orders WHERE customer_id = %(cid)s AND status = 'delivered'", {}),
          ("SELECT id FROM customers WHERE email = %(email)s", {}),
          ("SELECT max(placed_at) FROM orders WHERE customer_id = %(cid)s", {}),
          ("SELECT id, reference FROM orders WHERE customer_id = %(cid)s AND status = 'cancelled' LIMIT 5", {}),
          ("SELECT count(*) FROM orders WHERE customer_id = %(cid)s AND placed_at > now() - interval '30 days'", {}),
          ("SELECT created_at FROM customers WHERE id = %(cid)s", {}),
          ("SELECT 1", {}),
      ]


      def account(conn):
          cid = random.randint(1, 200000)
          args = {"cid": cid, "email": f"customer{random.randint(1, 200000)}@example.invalid"}
          with tracer.start_as_current_span("GET /account", kind=trace.SpanKind.SERVER):
              for sql, _ in PAGE:
                  with tracer.start_as_current_span(f"SELECT shop", kind=trace.SpanKind.CLIENT) as s:
                      s.set_attribute("db.system.name", "postgresql")
                      s.set_attribute("db.namespace", "shop")
                      s.set_attribute("db.operation.name", "SELECT")
                      s.set_attribute("db.query.text", sql)
                      s.set_attribute("server.address", "pg")
                      conn.execute(sql, args).fetchall()


      while True:
          try:
              with psycopg.connect("host=pg dbname=shop user=postgres password=devopslings", autocommit=True) as conn:
                  while True:
                      account(conn)
                      time.sleep(random.uniform(0.1, 0.3))
          except Exception as e:
              print(f"account page failed: {e}", flush=True)
              time.sleep(2)
      PY
      sha256sum /obs/apps/orders.py | cut -c1-64 > "$g/app.sha"
      cat > /obs/answers/slow-query.txt <<'TXT'
      # The statement that makes the account page slow. '#' starts a comment.
      query: ?      # its text, as db.query.text has it on the slow spans
      queryid: ?    # its queryid in pg_stat_statements
      TXT
      app_restart orders
      echo "scenario ready: orders serves the account page (GET /account), twelve queries per request"
      echo "against db-stack's primary (pg:5432, database shop, user postgres, password devopslings)."
      echo "Its spans are in Tempo:"
      echo "  curl -s -G http://tempo:3200/api/search --data-urlencode 'q={resource.service.name=\"orders\" && kind=client}' --data-urlencode spss=3 | jq"
      echo "Your answer: /obs/answers/slow-query.txt"
      BOX

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import hashlib, json, re, sys, time, urllib.parse, urllib.request
      import psycopg

      G = "/var/lib/devopslings/db-spans"
      ANSWER = "/obs/answers/slow-query.txt"
      SLOW = "SELECT id FROM customers WHERE email = %(email)s"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      try:
          want = open(f"{G}/app.sha").read().strip()
      except OSError:
          no("the scenario's files are missing. Reset the lesson.")
      if hashlib.sha256(open("/obs/apps/orders.py", "rb").read()).hexdigest() != want:
          no("/obs/apps/orders.py is not the account page this lesson started. The queries are what the",
             "application needs; the fix belongs in the database. Reset the lesson to get it back.")
      try:
          conn = psycopg.connect("host=pg dbname=shop user=postgres password=devopslings", autocommit=True, connect_timeout=5)
      except psycopg.Error as e:
          no(f"cannot reach the database at pg:5432 ({e}). Reset the lesson.")

      if conn.execute("SELECT count(*) FROM customers").fetchone()[0] < 200000:
          no("customers has lost rows. A statement over fewer rows is faster; the fix has to keep the",
             "data. Reset the lesson to get the table back.")

      def tail():
          try:
              return ["  " + l.rstrip()[:200] for l in open("/obs/logs/orders.log").readlines()[-3:]]
          except OSError:
              return ["  (no log)"]

      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""
      norm = lambda s: re.sub(r"\s+", " ", s).strip().rstrip(";").lower()

      q = field("query")
      if q in ("", "?"):
          no(f"query in {ANSWER} is not filled in.")
      stats = conn.execute("SELECT queryid, query, calls, mean_exec_time FROM pg_stat_statements "
                           "WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'shop')").fetchall()
      truth = [r for r in stats if norm(r[1]) == norm(SLOW.replace("%(email)s", "$1"))]
      if norm(q) != norm(SLOW) and norm(q) != norm(SLOW.replace("%(email)s", "$1")):
          mine = [r for r in stats if "join" in norm(r[1]) and "join" in norm(q)]
          if mine:
              no(f"that is the big join. pg_stat_statements has it at a mean of {mine[0][3]:.2f}ms per call: it",
                 "reads one customer's orders through the customer_id index. Sort the account page's",
                 "CLIENT spans by duration and read db.query.text on the slowest.")
          no(f"query is '{q}'. Copy db.query.text from the slowest CLIENT spans of GET /account.")
      if not truth:
          no("pg_stat_statements has no entry for that statement yet. Is the account page running? The",
             "end of /obs/logs/orders.log:", *tail())
      qid = field("queryid")
      if not re.fullmatch(r"-?\d+", qid or ""):
          no(f"queryid is '{qid}'. It is the queryid column of the statement's row in pg_stat_statements.")
      if int(qid) != truth[0][0]:
          no(f"queryid {qid} is not that statement's row in pg_stat_statements. The text there has $1",
             "where the application's text has its placeholder.")

      # The fix: the statement's own spans, over the last 20 seconds.
      time.sleep(3)
      now = int(time.time())
      tq = '{resource.service.name="orders" && span.db.query.text="' + SLOW + '"}'
      p = urllib.parse.urlencode({"q": tq, "start": now - 20, "end": now, "limit": 200, "spss": 20})
      try:
          with urllib.request.urlopen(f"http://tempo:3200/api/search?{p}", timeout=15) as r:
              found = json.load(r).get("traces", [])
      except OSError as e:
          no(f"Tempo did not answer a search ({e}).")
      ds = sorted(int(s["durationNanos"]) / 1e6 for t in found for ss in t.get("spanSets", []) for s in ss.get("spans", []))
      if len(ds) < 10:
          no(f"Tempo has {len(ds)} spans of that statement from the last 20s; the account page runs it",
             "several times a second. Is it running? See /obs/logs/orders.log.")
      p95 = ds[int(len(ds) * 0.95) - 1]
      if p95 > 5:
          no(f"that statement's spans take p95 {p95:.1f}ms over the last 20s. The stated target is under",
             "5ms. Look at its plan: EXPLAIN ANALYZE, with a real email.")
      print(f"PASS — the slow statement is the email lookup (queryid {qid}); its spans now take p95")
      print(f"{p95:.1f}ms.")
      PY
---
