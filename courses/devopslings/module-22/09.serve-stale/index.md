---
kind: lesson
title: "Serve stale: degrade instead of 500"
description: |
  The catalog page reads the database on every request, so when the
  database stops answering, every customer gets a 500 and a month's error
  budget goes in a minute. Serve the last good answer instead — and say
  plainly that it is old.
name: serve-stale
slug: serve-stale
createdAt: "2026-10-16"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /ha/app/routes
      cat > /ha/app/routes/catalog.py <<'PY'
      # GET /catalog on web1 and web2. handle(db) returns (status, body) or
      # (status, body, {headers}); a dict body is sent as JSON. Saved changes
      # apply to the next request.


      def handle(db):
          with db() as conn:
              count, newest = conn.execute(
                  "SELECT count(*), coalesce(max(id), 0) FROM orders"
              ).fetchone()
          return 200, {"orders": count, "newest": newest}
      PY
      for _ in $(seq 20); do curl -fsS --max-time 1 http://www/catalog >/dev/null 2>&1 && break; sleep 0.5; done
      echo "scenario ready — the catalog, through www:"
      echo
      curl -s -i http://www/catalog | grep -Ev '^(Content-Length|Content-Type):'
      echo
      echo "  the route:           /ha/app/routes/catalog.py"
      echo "  take the database:   node pause pg1      (node resume pg1)"
      echo "  watch it fail:       for i in 1 2 3; do curl -si http://www/catalog | head -1; done"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      paused=""
      work=$(mktemp -d)
      trap '[ -n "$paused" ] && docker unpause devopslings-ha-pg1 >/dev/null 2>&1; rm -rf "$work"; true' EXIT
      for _ in $(seq 30); do pg_isready -q -h pg1 && break; sleep 1; done

      if [ ! -s /ha/app/routes/catalog.py ]; then
        echo "not yet: /ha/app/routes/catalog.py is missing or empty."
        exit 1
      fi
      # One request through www: sets code, newest, stale (the X-Stale header, or empty).
      fetch() {
        code=$(curl -s -D "$work/h" -o "$work/b" --max-time 8 -w '%{http_code}' http://www/catalog || true)
        newest=$(jq -r '.newest // empty' "$work/b" 2>/dev/null || true)
        stale=$(awk -F': *' 'tolower($1) == "x-stale" { sub(/\r$/, "", $2); print $2 }' "$work/h")
        who=$(awk -F': *' 'tolower($1) == "x-served-by" { sub(/\r$/, "", $2); print $2 }' "$work/h")
      }

      # Fresh: the answer reflects the latest order, with no stale label.
      want=$(curl -fsS --max-time 8 -X POST 'http://www/orders?ref=stale-probe' | jq -r .id)
      for _ in $(seq 6); do
        fetch
        if [ "$code" != 200 ] || [ "$newest" != "$want" ]; then
          echo "not yet: with the database up, /catalog on $who answered $code with newest='$newest'."
          echo "         The order just placed has id $want. A fresh answer has to show it."
          exit 1
        fi
        if [ -n "$stale" ]; then
          echo "not yet: with the database up, /catalog on $who carries X-Stale: $stale."
          echo "         The label has to mean something: only an answer that could not be refreshed is stale."
          exit 1
        fi
      done
      echo "database up: fresh answers, newest=$want, no stale label"

      # Down: the last good answer, labelled, and no errors.
      docker pause devopslings-ha-pg1 >/dev/null
      paused=1
      sleep 2
      total=0; failed=0; bad=""
      for _ in $(seq 8); do
        fetch
        total=$((total + 1))
        if [ "$code" != 200 ]; then
          failed=$((failed + 1))
          bad=${bad:-"$who answered $code: $(head -c 120 "$work/b")"}
          continue
        fi
        if [ "$newest" != "$want" ]; then
          echo "not yet: with the database down, /catalog on $who answered 200 with newest='$newest'."
          echo "         The last good answer had newest=$want. Stale means the last thing that was true,"
          echo "         not an empty or made-up page."
          exit 1
        fi
        if ! [[ "$stale" =~ ^[0-9]+$ ]]; then
          echo "not yet: with the database down, /catalog on $who answered 200 with the old data,"
          if [ -z "$stale" ]; then
            echo "         and nothing says it is old. Stale content needs a label: X-Stale: <age in seconds>."
          else
            echo "         labelled X-Stale: $stale. The label is the age in whole seconds, so a client can decide."
          fi
          exit 1
        fi
      done
      if [ "$failed" -gt 0 ]; then
        echo "not yet: with the database down, $failed of $total requests to /catalog failed."
        echo "         e.g. $bad"
        echo "         Each one is spent from the error budget. The page had a good answer a moment ago."
        exit 1
      fi
      echo "database down: $total of $total answered from the last good copy, labelled X-Stale: $stale"

      docker unpause devopslings-ha-pg1 >/dev/null
      paused=""
      for _ in $(seq 30); do pg_isready -q -h pg1 && break; sleep 1; done
      want=$(curl -fsS --max-time 8 -X POST 'http://www/orders?ref=stale-probe' | jq -r .id)
      ok=""
      for _ in $(seq 10); do
        fresh=0
        for _ in 1 2 3 4; do
          fetch
          [ "$code" = 200 ] && [ "$newest" = "$want" ] && [ -z "$stale" ] && fresh=$((fresh + 1))
        done
        [ "$fresh" = 4 ] && { ok=1; break; }
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "not yet: the database is back and a new order (id $want) was placed, but 10 seconds"
        echo "         later /catalog on $who still answers newest='$newest' X-Stale='$stale'."
        echo "         Stale is a fallback, not a cache that stops looking."
        exit 1
      fi
      echo "database back: fresh again, newest=$want"
      echo
      echo "PASS — the outage cost no errors, and nobody was told old data was new."
