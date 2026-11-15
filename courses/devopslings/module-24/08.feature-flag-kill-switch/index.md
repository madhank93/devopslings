---
kind: lesson
title: "Feature flag as a kill switch"
description: |
  The new recommendation ranker is failing a third of its requests, and the
  only way to turn it off is a deploy. Make it a switch you flip in the
  database and that takes effect in seconds — then clean out the flags that
  stopped being switches a year ago.
name: feature-flag-kill-switch
slug: feature-flag-kill-switch
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/app/routes /ha/sre
      psql -qX <<'SQL'
      DROP SCHEMA IF EXISTS ff CASCADE;
      CREATE SCHEMA ff;
      CREATE TABLE ff.flags (
        name       text PRIMARY KEY,
        enabled    boolean NOT NULL,
        changed_at timestamptz NOT NULL DEFAULT now()
      );
      INSERT INTO ff.flags VALUES
        ('new_ranker',     true,  now() - interval '2 days'),
        ('dark_mode',      true,  now() - interval '412 days'),
        ('holiday_banner', false, now() - interval '318 days'),
        ('legacy_tax',     false, now() - interval '700 days');
      SQL
      cat > /ha/app/routes/recommend.py <<'PY'
      # GET /recommend — what to show a customer next.
      import random

      # Set at release. The ff.flags table was meant to replace this.
      FLAGS = {"new_ranker": True, "dark_mode": True, "holiday_banner": False}


      def flag(db, name):
          return FLAGS[name]


      def new_ranker():
          if random.random() < 0.3:
              raise TimeoutError("ranking service did not answer in 800 ms")
          return ["socks", "boots", "scarf"]


      def old_ranker():
          return ["socks", "hat", "gloves"]


      def handle(db):
          if flag(db, "new_ranker"):
              path = "new"
              try:
                  items = new_ranker()
              except TimeoutError as e:
                  return 500, f"recommend failed: {e}", {"X-Path": path}
          else:
              path, items = "old", old_ranker()
          body = {"items": items, "theme": "dark" if flag(db, "dark_mode") else "light"}
          if flag(db, "holiday_banner"):
              body["banner"] = "holiday sale: 20% off everything"
          return 200, body, {"X-Path": path}
      PY
      cat > /ha/sre/flag-audit <<'SH'
      #!/bin/bash
      # flag-audit — what the quarterly flag review checks. No output means clean.
      #   stale:       a flag nobody has changed in 90 days is not a switch any more
      #   orphan:      a flag in ff.flags that no route reads
      #   undeclared:  a route reads a flag that ff.flags does not have
      set -eu
      used=$(grep -rhoE "flag\(db, *[\"'][a-z_]+[\"']\)" /ha/app/routes 2>/dev/null | grep -oE "[\"'][a-z_]+[\"']" | tr -d "\"'" | sort -u || true)
      have=$(psql -qtAX -c "SELECT name FROM ff.flags ORDER BY 1")
      psql -qtAX -F' ' -c "SELECT name, (now() - changed_at)::interval(0) FROM ff.flags WHERE changed_at < now() - interval '90 days' ORDER BY 1" \
        | while read -r n age; do [ -n "$n" ] && echo "stale:      $n (unchanged for $age)"; done
      comm -13 <(echo "$used") <(echo "$have") | sed '/^$/d; s/^/orphan:     /'
      comm -23 <(echo "$used") <(echo "$have") | sed '/^$/d; s/^/undeclared: /'
      SH
      chmod +x /ha/sre/flag-audit
      cp /ha/sre/flag-audit /var/lib/devopslings/flag-audit
      for _ in $(seq 20); do curl -fsS --max-time 2 http://www/ >/dev/null 2>&1 && break; sleep 0.5; done
      echo "scenario ready — recommendations through www, ten in a row:"
      for _ in $(seq 10); do curl -s -o /dev/null -w '%{http_code} ' --max-time 3 http://www/recommend; done
      echo
      echo
      echo "  the code:          /ha/app/routes/recommend.py"
      echo "  the flag store:    psql -c 'TABLE ff.flags'"
      echo "  the flag review:   /ha/sre/flag-audit"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      audit=/var/lib/devopslings/flag-audit
      route=/ha/app/routes/recommend.py
      if [ ! -x "$audit" ]; then
        echo "not yet: the scenario's flag audit is missing. Reset the lesson."
        exit 1
      fi
      if [ ! -f "$route" ]; then
        echo "not yet: $route is gone; the shop has no recommendations."
        exit 1
      fi
      restore() { psql -qX -c "ALTER TABLE IF EXISTS ff.flags_unreachable RENAME TO flags" >/dev/null 2>&1 || true; }
      trap restore EXIT
      restore
      body() { curl -s --max-time 5 "http://$1/recommend" 2>/dev/null || true; }
      paths() {  # paths <n> — the X-Path of n requests through www, one per line
        local _
        for _ in $(seq "$1"); do
          curl -s -o /dev/null -D - --max-time 5 http://www/recommend 2>/dev/null | tr -d '\r' \
            | awk -F': ' 'tolower($1) == "x-path" { print $2 }' || true
        done
      }
      within() {  # within <seconds> <old|new> — 10 requests in a row all on that path
        local i
        for i in $(seq $(($1 * 2))); do
          [ "$(paths 10 | sort -u | tr -d '\n')" = "$2" ] && { took=$(awk -v i="$i" 'BEGIN { printf "%.1f", i / 2 }'); return 0; }
          sleep 0.5
        done
        return 1
      }
      setflag() { psql -qX -c "UPDATE ff.flags SET enabled = $2, changed_at = now() WHERE name = '$1'" >/dev/null; }

      # The switch.
      if [ "$(psql -qtAX -c "SELECT count(*) FROM ff.flags WHERE name = 'new_ranker'")" != 1 ]; then
        echo "not yet: ff.flags has no new_ranker row. That row is the kill switch; it stays."
        exit 1
      fi
      setflag new_ranker true
      if ! within 10 new; then
        echo "not yet: the grader set new_ranker on in ff.flags, and 10 seconds later www was not serving the"
        echo "         new ranker. The flag has to come from ff.flags; the paths seen: $(paths 10 | sort | uniq -c | tr -s ' \n' ' ')"
        exit 1
      fi
      setflag new_ranker false
      if ! within 5 old; then
        seen=$(paths 10 | sort | uniq -c | tr -s ' \n' ' ')
        echo "not yet: the grader turned new_ranker off in ff.flags, and 5 seconds later requests still take the"
        echo "         new ranker ($seen). A kill switch that waits for a cache to expire, or for the code to be"
        echo "         loaded again, is a deploy with extra steps: read the flag on every request, or cache it"
        echo "         for no more than a second or two."
        exit 1
      fi
      echo "new_ranker off in ff.flags: every request on the old ranker within ${took}s"

      # The flag store goes away; the switch must fail safe, not fail the request.
      psql -qX -c "ALTER TABLE ff.flags RENAME TO flags_unreachable" >/dev/null
      sleep 3
      codes=$(for _ in $(seq 10); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://www/recommend || true; done | sort | uniq -c | tr -s ' \n' ' ')
      newp=$(paths 10 | grep -c new || true)
      sample=$(body www | cut -c1-160)
      restore
      if [ "$codes" != " 10 200 " ]; then
        echo "not yet: with ff.flags unreachable, /recommend answered:$codes"
        echo "         | $sample"
        echo "         When the flag store cannot answer, every flag needs a value it falls back to. A lookup"
        echo "         that raises takes the whole page down with it."
        exit 1
      fi
      if [ "$newp" -gt 0 ]; then
        echo "not yet: with ff.flags unreachable, $newp of 10 requests took the new ranker. The safe value of"
        echo "         a kill switch, when nobody can tell you its state, is off: the old path."
        exit 1
      fi
      echo "flag store unreachable: pages still served, on the old ranker"

      # The flag review. A fresh changed_at on a flag nobody flipped hides it from the audit.
      kept=$(psql -qtAX -c "SELECT string_agg(name, ', ' ORDER BY name) FROM ff.flags WHERE name IN ('dark_mode', 'holiday_banner', 'legacy_tax')" 2>/dev/null || true)
      if [ -n "$kept" ]; then
        echo "not yet: ff.flags still has $kept. Each had held one value for most of a year; if"
        echo "         changed_at says otherwise now, the review passes and the dead flag stays. Keep the"
        echo "         behaviour it had, delete the branch, delete the row."
        exit 1
      fi
      out=$("$audit" 2>&1 || true)
      if [ -n "$out" ]; then
        echo "not yet: the flag review is not clean:"
        printf '%s\n' "$out" | sed 's/^/         | /'
        case $out in *stale:*)
          echo "         A flag that has been the same for over a year is a constant with a database"
          echo "         round-trip. Keep the behaviour it has had, delete the branch, delete the row." ;; esac
        exit 1
      fi
      b=$(body www)
      case $b in *'"theme": "dark"'*) ;; *)
        echo "not yet: the review is clean, but recommendations now say: $(printf '%s' "$b" | cut -c1-160)"
        echo "         dark_mode had been on for every customer for over a year. Removing the flag should"
        echo "         keep the theme it gave everyone. A flag the code still asks for after its row is"
        echo "         gone reads as off." ;
        exit 1 ;;
      esac
      case $b in *banner*)
        echo "not yet: the review is clean, but recommendations now show the holiday banner, which had been"
        echo "         off for 318 days. Removing a flag keeps the behaviour it had."
        exit 1 ;;
      esac
      echo "flag review clean; dark theme kept, no banner"
      echo
      echo "PASS — new_ranker is a switch in ff.flags that works in seconds and fails safe, and the stale flags are gone."
---
