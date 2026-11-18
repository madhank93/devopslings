---
kind: lesson
title: "One expiry takes the database down"
description: |
  The catalog cache holds every product for 15 seconds, and catalog-db is
  fine for 14.9 of them. Then the entries expire together, every request in
  flight misses at once, and the database refuses connections. Make an expiry
  cost the database one query per product.
name: cache-stampede
slug: cache-stampede
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.cache-stampede
      lesson=$1
      mkdir -p answers
      cp "$lesson/files/cache.py" answers/cache.py
      cp "$lesson/files/browse.js" answers/browse.js
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — the catalog API is on checkout:8230, catalog-db on checkout:8231."
      echo
      echo "The cache is answers/cache.py. Apply a change with:  bash $lesson/files/deploy.sh"
      echo "Replay the shoppers (300 requests a second, 35 seconds):"
      echo "  docker compose exec -T k6 k6 run - < answers/browse.js"
      echo "catalog-db's counters:"
      echo "  docker compose exec -T checkout python3 -c \"import urllib.request as u; print(u.urlopen('http://localhost:8231/stats').read().decode())\""

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.cache-stampede
      lesson=$1
      [ -s answers/cache.py ] || { echo "not yet: answers/cache.py is missing — rerun the lesson's init to get it back."; exit 1; }
      if ! bash "$lesson/files/deploy.sh" >/dev/null 2>&1; then
        echo "not yet: the catalog API did not start with answers/cache.py. Its log:"
        docker compose exec -T checkout tail -5 /srv/cache-stampede/api.log 2>/dev/null || true
        exit 1
      fi
      inbox() { docker compose exec -T checkout python3 -c "$1" 2>/dev/null || true; }
      # Every product loaded at the same moment, as after a deploy or a flush,
      # so they all expire together; then catalog-db's counters start from zero.
      inbox 'import urllib.request as u; u.urlopen("http://localhost:8230/warm", timeout=60).read(); u.urlopen(u.Request("http://localhost:8231/reset", method="POST")).read()'
      sj=$(docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 run --quiet --summary-export=/tmp/s.json /tmp/s.js >/dev/null 2>&1; cat /tmp/s.json' \
        < "$lesson/files/browse.js" 2>/dev/null || true)
      db=$(inbox 'import urllib.request as u; print(u.urlopen("http://localhost:8231/stats").read().decode())')
      served=$(jq -r '.metrics.checks.value // empty' <<<"$sj" 2>/dev/null || true)
      stale=$(jq -r '.metrics.staleness_s.max // empty | . * 10 | round / 10' <<<"$sj" 2>/dev/null || true)
      p99=$(jq -r '.metrics.http_req_duration["p(99)"] // empty | round' <<<"$sj" 2>/dev/null || true)
      calls=$(jq -r '.calls // empty' <<<"$db" 2>/dev/null || true)
      refused=$(jq -r '.refused // empty' <<<"$db" 2>/dev/null || true)
      peak=$(jq -r '.peak_inflight // empty' <<<"$db" 2>/dev/null || true)
      if [ -z "$served" ] || [ -z "$calls" ]; then
        echo "not yet: the shoppers' run did not finish. Run answers/browse.js yourself and read the API's"
        echo "log: docker compose exec -T checkout tail /srv/cache-stampede/api.log"
        exit 1
      fi
      pct=$(awk -v v="$served" 'BEGIN { printf "%.2f", v * 100 }')
      echo "this check measured over 35 seconds: ${pct}% of requests served, p99 ${p99}ms, oldest price ${stale:-?}s;"
      echo "catalog-db: $calls queries, $refused refused, at most $peak running at once (it has 30 connections)"

      if [ -z "$stale" ] || awk -v s="$stale" 'BEGIN { exit !(s > 15.5) }'; then
        echo "not yet: shoppers were shown prices up to ${stale:-?} seconds old, and the limit is 15."
        if [ -n "$stale" ] && awk -v s="$stale" 'BEGIN { exit !(s <= 20) }'; then
          echo "Some entries lived past 15 seconds. If you spread expiries out with jitter, the jitter"
          echo "has to shorten lifetimes below the limit, not stretch them past it."
          exit 1
        fi
        echo "A longer TTL does not remove the stampede, it postpones it: every product still expires"
        echo "at the same moment, just less often. Keep entries at most 15 seconds old and change what"
        echo "happens when they expire."
        exit 1
      fi
      if [ "$refused" != 0 ] || [ "$served" != 1 ]; then
        echo "not yet: catalog-db refused $refused queries and ${pct}% of requests were served. When the"
        echo "products expire, every request in flight for one of them misses and queries catalog-db"
        echo "itself, all at once — dozens of queries for 20 products, each one slowing the rest."
        echo "An expiry should cost catalog-db about one query per product."
        exit 1
      fi
      if [ "$p99" -ge 1000 ]; then
        echo "not yet: catalog-db was safe, but the p99 is ${p99}ms. Requests waited on each other far"
        echo "longer than one 150ms query: a lock shared by every product makes a request for a fresh"
        echo "product wait behind the reload of an expired one."
        exit 1
      fi
      echo "PASS — 20 products expired together and catalog-db saw $calls queries, never more than $peak at once."
---
