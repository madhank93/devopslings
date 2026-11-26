---
kind: lesson
title: "v2 is a third slower, and the diff is forty files"
description: |
  v2 renders product pages a third slower than v1. Its diff touches forty
  files, and the two flame graphs side by side look the same except for a
  little noise everywhere. Ask Pyroscope for the difference instead of
  squinting at two pictures, revert the one change it points at, and show v2
  back level with v1 on the same benchmark.
name: differential-flame-graph
slug: differential-flame-graph
createdAt: "2026-11-22"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      # Stop every profiled app this module starts, whichever lesson left it running:
      # they share the CPU this lesson's numbers are read from.
      pkill -f '^bash [^ ]*/supervise (pricing|catalog-v[12]|quoter|quotes) ' 2>/dev/null || true
      pkill -f '^python3 /obs/(pricing|catalog|quoter|quotes)/' 2>/dev/null || true
      rm -rf /obs/catalog /obs/run/catalog-* /obs/logs/catalog-*.log
      mkdir -p /obs/catalog/v1/templates

      cat > /obs/catalog/v1/render.py <<'PY'
      """Product page renderer: header, listing, reviews, footer."""
      from listing import format_listing
      from reviews import summarize_reviews
      from seo import meta_tags
      from text import slug, title_case


      def render_page(product):
          parts = [
              f"<title>{title_case(product['name'])}</title>",
              meta_tags(product),
              f"<a href='/p/{slug(product['name'])}'>",
              format_listing(product),
              summarize_reviews(product["reviews"]),
          ]
          return "\n".join(parts)
      PY
      cat > /obs/catalog/v1/listing.py <<'PY'
      """The variant table: one row per size/colour, with price and stock."""
      from money import format_price
      from stock import stock_label


      def format_listing(product):
          rows = []
          for v in product["variants"]:
              rows.append(f"<tr><td>{v['sku']}</td><td>{format_price(v['cents'], product['currency'])}</td>"
                          f"<td>{stock_label(v['stock'])}</td></tr>")
          return "<table>" + "".join(rows) + "</table>"
      PY
      cat > /obs/catalog/v1/money.py <<'PY'
      """Price formatting."""
      from currencies import CURRENCIES

      SYMBOLS = {c["code"]: c["symbol"] for c in CURRENCIES}


      def format_price(cents, currency):
          return f"{SYMBOLS[currency]}{cents / 100:,.2f}"
      PY
      cat > /obs/catalog/v1/currencies.py <<'PY'
      """ISO 4217 currencies the storefront can display."""
      CURRENCIES = [
          {"code": "CTA", "symbol": "CTA ", "decimals": 2},
          {"code": "DBE", "symbol": "DBE ", "decimals": 2},
          {"code": "DCP", "symbol": "DCP ", "decimals": 2},
          {"code": "EHU", "symbol": "EHU ", "decimals": 2},
          {"code": "ELT", "symbol": "ELT ", "decimals": 2},
          {"code": "EQM", "symbol": "EQM ", "decimals": 2},
          {"code": "EUR", "symbol": "€", "decimals": 2},
          {"code": "GBP", "symbol": "£", "decimals": 2},
          {"code": "HGW", "symbol": "HGW ", "decimals": 2},
          {"code": "HSR", "symbol": "HSR ", "decimals": 2},
          {"code": "IPT", "symbol": "IPT ", "decimals": 2},
          {"code": "ITV", "symbol": "ITV ", "decimals": 2},
          {"code": "JYA", "symbol": "JYA ", "decimals": 2},
          {"code": "KRS", "symbol": "KRS ", "decimals": 2},
          {"code": "KVA", "symbol": "KVA ", "decimals": 2},
          {"code": "LRS", "symbol": "LRS ", "decimals": 2},
          {"code": "LZC", "symbol": "LZC ", "decimals": 2},
          {"code": "NEA", "symbol": "NEA ", "decimals": 2},
          {"code": "NSH", "symbol": "NSH ", "decimals": 2},
          {"code": "OEL", "symbol": "OEL ", "decimals": 2},
          {"code": "PGI", "symbol": "PGI ", "decimals": 2},
          {"code": "PIR", "symbol": "PIR ", "decimals": 2},
          {"code": "PMU", "symbol": "PMU ", "decimals": 2},
          {"code": "PRR", "symbol": "PRR ", "decimals": 2},
          {"code": "PUS", "symbol": "PUS ", "decimals": 2},
          {"code": "QMS", "symbol": "QMS ", "decimals": 2},
          {"code": "SDW", "symbol": "SDW ", "decimals": 2},
          {"code": "SIJ", "symbol": "SIJ ", "decimals": 2},
          {"code": "UGU", "symbol": "UGU ", "decimals": 2},
          {"code": "UJN", "symbol": "UJN ", "decimals": 2},
          {"code": "UPC", "symbol": "UPC ", "decimals": 2},
          {"code": "USD", "symbol": "$", "decimals": 2},
          {"code": "VNY", "symbol": "VNY ", "decimals": 2},
          {"code": "WFW", "symbol": "WFW ", "decimals": 2},
          {"code": "XAV", "symbol": "XAV ", "decimals": 2},
          {"code": "XMW", "symbol": "XMW ", "decimals": 2},
          {"code": "XZS", "symbol": "XZS ", "decimals": 2},
          {"code": "YCF", "symbol": "YCF ", "decimals": 2},
          {"code": "YSB", "symbol": "YSB ", "decimals": 2},
          {"code": "ZNM", "symbol": "ZNM ", "decimals": 2},
      ]
      PY
      cat > /obs/catalog/v1/stock.py <<'PY'
      """Stock wording."""


      def stock_label(n):
          if n == 0:
              return "Out of stock"
          if n < 5:
              return f"Only {n} left"
          return "In stock"
      PY
      cat > /obs/catalog/v1/reviews.py <<'PY'
      """Review summary: average stars and the newest three."""


      def summarize_reviews(reviews):
          if not reviews:
              return "<p>No reviews yet</p>"
          avg = sum(r["stars"] for r in reviews) / len(reviews)
          newest = sorted(reviews, key=lambda r: r["at"], reverse=True)[:3]
          quotes = "".join(f"<blockquote>{r['text'][:140]}</blockquote>" for r in newest)
          return f"<p>{avg:.1f} stars from {len(reviews)} reviews</p>{quotes}"
      PY
      cat > /obs/catalog/v1/seo.py <<'PY'
      """Meta tags for search engines."""
      from text import slug


      def meta_tags(product):
          desc = " ".join(product["description"].split())[:155]
          return (f"<meta name='description' content='{desc}'>"
                  f"<link rel='canonical' href='https://shop.example/p/{slug(product['name'])}'>")
      PY
      cat > /obs/catalog/v1/text.py <<'PY'
      """Small string helpers."""
      import re

      _NON_WORD = re.compile(r"[^a-z0-9]+")


      def slug(s):
          return _NON_WORD.sub("-", s.lower()).strip("-")


      def title_case(s):
          return " ".join(w.capitalize() for w in s.split())
      PY
      cat > /obs/catalog/v1/products.py <<'PY'
      """A fixed catalogue sample for the benchmark and the traffic generator."""
      import random


      def sample(n=200, seed=42):
          rng = random.Random(seed)
          out = []
          for i in range(n):
              out.append({
                  "name": f"trail runner {i} gore-tex",
                  "currency": rng.choice(["EUR", "GBP", "USD"]),
                  "description": "Lightweight shoe with a grippy outsole. " * 6,
                  "variants": [{"sku": f"TR{i:04d}-{s}", "cents": rng.randint(4000, 25000),
                                "stock": rng.randint(0, 40)} for s in range(24)],
                  "reviews": [{"stars": rng.randint(1, 5), "at": rng.random(), "text": "Fits well. " * 20}
                              for _ in range(rng.randint(0, 30))],
              })
          return out
      PY
      for i in $(seq -w 1 33); do
        printf '<section class="promo-%s">\n  <h2>Free returns within 30 days</h2>\n</section>\n' "$i" \
          > /obs/catalog/v1/templates/promo-$i.html
      done
      cp -a /obs/catalog/v1 /obs/catalog/v2
      # v2: the release under investigation. One of these forty changes is the regression.
      for i in $(seq -w 1 33); do
        printf '<section class="promo promo-%s">\n  <h2>Free returns for 30 days</h2>\n</section>\n' "$i" \
          > /obs/catalog/v2/templates/promo-$i.html
      done
      cat > /obs/catalog/v2/render.py <<'PY'
      """Product page renderer: header, listing, reviews, footer."""
      from listing import format_listing
      from reviews import summarize_reviews
      from seo import meta_tags
      from text import slug, title_case


      def render_page(product):
          name = product["name"]
          parts = [
              f"<title>{title_case(name)}</title>",
              meta_tags(product),
              "<link rel='preload' href='/static/listing.css' as='style'>",
              f"<a href='/p/{slug(name)}'>",
              format_listing(product),
              summarize_reviews(product["reviews"]),
          ]
          return "\n".join(parts)
      PY
      cat > /obs/catalog/v2/listing.py <<'PY'
      """The variant table: one row per size/colour, with price and stock."""
      from money import format_price
      from stock import stock_label


      def format_listing(product):
          rows = []
          for v in product["variants"]:
              rows.append(f"<tr data-sku='{v['sku']}'><td>{v['sku']}</td>"
                          f"<td>{format_price(v['cents'], product['currency'])}</td>"
                          f"<td>{stock_label(v['stock'])}</td></tr>")
          return "<table class='variants'>" + "".join(rows) + "</table>"
      PY
      cat > /obs/catalog/v2/money.py <<'PY'
      """Price formatting."""

      from currencies import CURRENCIES

      def _symbol(code):
          for c in CURRENCIES:
              if c["code"] == code:
                  return c["symbol"]
          raise KeyError(code)

      def format_price(cents, currency):
          return f"{_symbol(currency)}{cents / 100:,.2f}"
      PY
      cat > /obs/catalog/v2/stock.py <<'PY'
      """Stock wording."""

      LOW = 5


      def stock_label(n):
          if n <= 0:
              return "Out of stock"
          if n < LOW:
              return f"Low stock: {n} left"
          return "In stock"
      PY
      cat > /obs/catalog/v2/reviews.py <<'PY'
      """Review summary: average stars and the newest three."""
      from operator import itemgetter


      def summarize_reviews(reviews):
          if not reviews:
              return "<p>No reviews yet</p>"
          avg = sum(r["stars"] for r in reviews) / len(reviews)
          newest = sorted(reviews, key=itemgetter("at"), reverse=True)[:3]
          quotes = "".join(f"<blockquote>{r['text'][:140]}</blockquote>" for r in newest)
          return f"<p>{avg:.1f} stars from {len(reviews)} reviews</p>{quotes}"
      PY
      cat > /obs/catalog/v2/seo.py <<'PY'
      """Meta tags for search engines."""
      from text import slug


      def meta_tags(product):
          desc = " ".join(product["description"].split())
          if len(desc) > 155:
              desc = desc[:155].rsplit(" ", 1)[0] + "…"
          return (f"<meta name='description' content='{desc}'>"
                  f"<link rel='canonical' href='https://shop.example/p/{slug(product['name'])}'>")
      PY
      cat > /obs/catalog/v2/text.py <<'PY'
      """Small string helpers."""
      import re

      _NON_WORD = re.compile(r"[^a-z0-9]+")


      def slug(s):
          return _NON_WORD.sub("-", s.lower()).strip("-")


      def title_case(s):
          return s.title()
      PY
      cat > /obs/catalog/bench.py <<'PY'
      """bench.py DIR [SECONDS] — render the sample catalogue with the code in DIR
      for SECONDS of CPU (default 3) and print pages per CPU second."""
      import json, sys, time
      sys.path.insert(0, sys.argv[1])
      from render import render_page
      from products import sample

      pages = sample()
      secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
      for p in pages[:20]:
          render_page(p)
      n, t0 = 0, time.process_time()
      while time.process_time() - t0 < secs:
          for p in pages:
              render_page(p)
          n += len(pages)
      print(json.dumps({"pages_per_cpu_s": round(n / (time.process_time() - t0), 1)}))
      PY
      cat > /obs/catalog/serve.py <<'PY'
      """serve.py DIR VERSION — render product pages at a steady rate with the code
      in DIR, profiled to Pyroscope as service "catalog" tagged version=VERSION."""
      import os, sys, time
      import pyroscope

      sys.path.insert(0, sys.argv[1])
      pyroscope.configure(application_name="catalog", server_address=os.environ.get("PYROSCOPE", "http://pyroscope:4040"),
                          sample_rate=100, tags={"version": sys.argv[2]})
      from products import sample
      from render import render_page

      pages = sample()
      while True:
          start = time.monotonic()
          for _ in range(10):
              for p in pages:
                  render_page(p)
          time.sleep(max(0.0, 1 - (time.monotonic() - start)))
      PY
      chmod -R a+rX /obs/catalog
      cp -a /obs/catalog/v1 /obs/run/catalog-v1.orig
      cp -a /obs/catalog/v2 /obs/run/catalog-v2.orig
      cp /obs/catalog/bench.py /obs/run/catalog-bench.py

      for _ in $(seq 1 60); do curl -fs -m 2 "$PYROSCOPE/ready" >/dev/null 2>&1 && break; sleep 1; done
      for v in v1 v2; do
        setsid supervise catalog-$v python3 /obs/catalog/serve.py /obs/catalog/$v $v </dev/null >/dev/null 2>&1 &
      done

      q='process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name="catalog",version="v2"}'
      for _ in $(seq 1 90); do
        ticks=$(curl -s -m 5 -G "$PYROSCOPE/pyroscope/render" --data-urlencode "query=$q" \
                  --data-urlencode from=now-5m --data-urlencode until=now --data-urlencode format=json |
                jq -r '.flamebearer.numTicks // 0' 2>/dev/null || echo 0)
        [ "${ticks:-0}" != 0 ] && break
        sleep 2
      done
      if [ "${ticks:-0}" = 0 ]; then
        echo "scenario setup failed: no profile for catalog v2 reached Pyroscope" >&2
        exit 1
      fi

      echo "scenario ready — catalog v1 and v2 both render pages and profile to Pyroscope as"
      echo "service_name=\"catalog\", tagged version=v1 and version=v2 (Pyroscope UI: http://localhost:14040)."
      echo "Code: /obs/catalog/v1 and /obs/catalog/v2. Benchmark: python3 /obs/catalog/bench.py /obs/catalog/v2"

  verify_done:
    timeout_seconds: 180
    run: |
      python3 - <<'PY'
      import json, subprocess, sys, textwrap

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)

      ans = {}
      try:
          for line in open("/obs/answers/regression.txt"):
              if "=" in line:
                  k, v = line.split("=", 1)
                  ans[k.strip()] = v.strip().strip('"')
      except OSError:
          pass
      fn = ans.get("regression", "").split(".")[-1].split("(")[0].strip()
      if not fn:
          no("/obs/answers/regression.txt needs regression=<function>: the frame Pyroscope's diff of",
             "version=v1 against version=v2 shows grown the most.")
      if fn in ("render_page", "format_listing", "<module>", "serve"):
          no(f"regression={fn} is wider in v2 because something it calls is. Follow the red down to",
             "the frame whose own share grew.")
      if fn in ("summarize_reviews", "meta_tags", "title_case", "slug", "stock_label", "sorted"):
          no(f"regression={fn} changed in v2, but its share of the profile did not grow. The diff view",
             "colours each frame by how much its share changed; find the darkest red.")
      if fn not in ("format_price", "_symbol"):
          no(f"regression={fn}. Compare version=v1 (baseline) with version=v2 (comparison) in",
             "Pyroscope's diff view and name the frame that grew.")

      if subprocess.run("diff -rq -x __pycache__ /obs/run/catalog-v1.orig /obs/catalog/v1",
                        shell=True, capture_output=True).returncode != 0:
          no("/obs/catalog/v1 has changed. v1 is the baseline the release is measured against: bring v2",
             "level with it, not it level with v2.")

      # The fix is a revert inside the release: every other file must stay as v2 shipped it.
      drift = [l for l in subprocess.run("diff -rq -x __pycache__ /obs/run/catalog-v2.orig /obs/catalog/v2",
                                         shell=True, capture_output=True, text=True).stdout.splitlines()
               if not l.startswith("Files /obs/run/catalog-v2.orig/money.py ")]
      if drift:
          names = sorted({l.split()[1].replace("/obs/run/catalog-v2.orig/", "") if l.startswith("Files")
                          else l.split(": ")[-1] for l in drift})
          it = "it" if len(names) == 1 else "them"
          no(f"v2 changed outside money.py: {', '.join(names[:5])}. Restore {it} as the release shipped",
             f"{it} (the originals: /obs/run/catalog-v2.orig); the fix is in money.py alone.")

      # Faster must not mean different: v2's prices have to render exactly as v1's.
      grid = r'''
      import json, sys
      sys.path.insert(0, sys.argv[1])
      from currencies import CURRENCIES
      from money import format_price
      print(json.dumps({f"{c} {n}": format_price(n, c) for c in sorted(x["code"] for x in CURRENCIES)
                        for n in (0, 1, 99, 100, 4000, 12345, 25000, 123456789)}))
      '''
      def prices(d):
          try:
              r = subprocess.run(["python3", "-c", textwrap.dedent(grid), d], capture_output=True, text=True, timeout=30)
          except subprocess.TimeoutExpired:
              no(f"{d}/money.py takes over 30 s to format a few hundred sample prices.")
          try:
              return json.loads(r.stdout.strip().splitlines()[-1])
          except (IndexError, ValueError):
              no(f"{d}/money.py fails when this check formats sample prices:", *r.stderr.strip().splitlines()[-3:])
      want, got = prices("/obs/run/catalog-v1.orig"), prices("/obs/catalog/v2")
      wrong = [k for k in want if got.get(k) != want[k]]
      if wrong:
          k = wrong[0]
          c, n = k.split()
          no(f"v2 formats prices differently from v1: format_price({n}, \"{c}\") gives {got.get(k)!r}, v1 gives",
             f"{want[k]!r} ({len(wrong)} of {len(want)} sample prices differ). Make it fast without changing its output.")

      def bench(d):
          try:
              r = subprocess.run(["python3", "/obs/run/catalog-bench.py", d, "2"], capture_output=True, text=True, timeout=60)
              return json.loads(r.stdout.strip().splitlines()[-1])["pages_per_cpu_s"]
          except subprocess.TimeoutExpired:
              no(f"{d} took over a minute on a two-second benchmark.")
          except (IndexError, ValueError, KeyError):
              no(f"{d} does not run under bench.py:", *r.stderr.strip().splitlines()[-3:])

      # The traffic loops share the CPU with the benchmark; pause them while it runs.
      subprocess.run("pkill -STOP -f '^python3 /obs/catalog/serve.py'", shell=True)
      try:
          runs = {"v1": [], "v2": []}
          for _ in range(3):
              for v in ("v1", "v2"):
                  runs[v].append(bench(f"/obs/catalog/{v}"))
      finally:
          subprocess.run("pkill -CONT -f '^python3 /obs/catalog/serve.py'", shell=True)
      v1, v2 = sorted(runs["v1"])[1], sorted(runs["v2"])[1]
      print(f"this check benchmarked each version three times, alternating: v1 {v1:.0f}, v2 {v2:.0f} pages per CPU second")
      if v2 < 0.95 * v1:
          no(f"v2 renders {v2:.0f} pages per CPU second against v1's {v1:.0f}: {100 * (1 - v2 / v1):.0f}% slower,",
             "and it needs to be within 5%.")
      print(f"PASS — {fn} was the regression; v2 now renders {v2:.0f} pages per CPU second against")
      print(f"       v1's {v1:.0f}, with the rest of the release untouched.")
      PY
---
