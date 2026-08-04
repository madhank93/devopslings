---
kind: lesson
title: "the regex that was right until someone wrote a sentence"
description: |
  slow-services reads a JSON log and reports which services were slow. It has
  been quietly wrong since a developer put the words "duration_ms" in an error
  message. Widening the pattern makes it wrong in a new way; the log is
  structured, so parse it.
name: parse-do-not-scrape
slug: parse-do-not-scrape
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/events /var/lib/devopslings /root/answers

      # A JSON-lines event log. Every record is valid JSON; several of them are
      # hostile to a line-oriented pattern, in ways that all occur in real logs.
      python3 - <<'PY'
      import json

      rows = [
          # Ordinary.
          {"ts": "2026-08-04T01:00:00Z", "service": "checkout", "duration_ms": 812, "message": "ok"},
          {"ts": "2026-08-04T01:00:01Z", "service": "search",   "duration_ms": 91,  "message": "ok"},

          # The message that broke it: it contains the literal text the pattern
          # was matching on, and a number that is not a duration.
          {"ts": "2026-08-04T01:00:02Z", "service": "cart", "duration_ms": 40,
           "message": 'upstream reported "duration_ms": 9999 which we ignore'},

          # A service name with a space in it.
          {"ts": "2026-08-04T01:00:03Z", "service": "order api", "duration_ms": 1503, "message": "slow"},

          # Fields in a different order, because a different service emits them.
          {"duration_ms": 640, "message": "ok", "service": "billing", "ts": "2026-08-04T01:00:04Z"},

          # A nested object that also has a duration_ms, which is NOT the
          # request's duration.
          {"ts": "2026-08-04T01:00:05Z", "service": "inventory", "duration_ms": 120,
           "message": "ok", "upstream": {"name": "warehouse", "duration_ms": 4200}},

          # Braces and quotes in the message.
          {"ts": "2026-08-04T01:00:06Z", "service": "auth", "duration_ms": 998,
           "message": 'parse error near "}" in {"tok": 1}'},

          # Exactly on the boundary — 500 is not > 500.
          {"ts": "2026-08-04T01:00:07Z", "service": "email", "duration_ms": 500, "message": "ok"},

          # Slow, and a duplicate service: the report lists each name once.
          {"ts": "2026-08-04T01:00:08Z", "service": "checkout", "duration_ms": 1900, "message": "slow"},
      ]
      with open("/srv/events/events.jsonl", "w") as f:
          for r in rows:
              f.write(json.dumps(r) + "\n")
      PY

      # Ground truth, computed from the structure rather than from the text.
      jq -r 'select(.duration_ms > 500) | .service' /srv/events/events.jsonl \
        | sort -u > /var/lib/devopslings/slow.expected

      cat > /usr/local/bin/slow-services <<'SH'
      #!/bin/bash
      # Report every service with a request slower than 500ms, one per line.
      #
      # Written when every record was flat, short, and machine-generated.
      set -euo pipefail
      grep -o '"duration_ms": *[0-9]*' /srv/events/events.jsonl \
        | awk -F: '$2 + 0 > 500' \
        | while read -r _; do :; done
      grep '"duration_ms": *[5-9][0-9][0-9]' /srv/events/events.jsonl \
        | sed -n 's/.*"service": *"\([^"]*\)".*/\1/p' \
        | sort -u
      SH
      chmod 0755 /usr/local/bin/slow-services

      cat > /root/questions.txt <<'Q'
      /usr/local/bin/slow-services reports which services had a request slower
      than 500ms, one service name per line, sorted, each name once.

      It is wrong. Fix it.

      The rules, precisely:

        - a record counts if its OWN duration_ms is strictly greater than 500
        - a duration_ms inside a nested object is not the request's duration
        - text inside "message" is text, never a field
        - print each qualifying service name once, sorted

      The check compares your script's stdout against the answer computed from
      the log's structure.
      Q

      echo "scenario ready — slow-services disagrees with the log it is reading"
      echo "  it currently prints:"
      /usr/local/bin/slow-services 2>/dev/null | sed 's/^/    /' || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      bin=/usr/local/bin/slow-services
      if [ ! -x "$bin" ]; then
        echo "not yet: $bin is missing or not executable"
        exit 1
      fi

      set +e
      got=$("$bin" 2>/tmp/slow.err); rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: $bin exited $rc"
        sed 's/^/         /' /tmp/slow.err | head -5
        exit 1
      fi

      want=$(cat /var/lib/devopslings/slow.expected)

      if [ "$got" = "$want" ]; then
        echo "PASS — $(printf '%s' "$want" | wc -l) services, read from the structure:"
        printf '%s\n' "$want" | sed 's/^/       /'
        exit 0
      fi

      echo "not yet: the output does not match the log."
      echo
      echo "  expected:"; printf '%s\n' "$want" | sed 's/^/    /'
      echo "  got:";      printf '%s\n' "$got"  | sed 's/^/    /'
      echo

      # Point at the specific record that a text-matching approach gets wrong.
      if printf '%s' "$got" | grep -qx 'cart'; then
        echo "  'cart' is in your output. Its duration_ms is 40. The 9999 you matched is"
        echo "  inside its message field, where a developer quoted an upstream response."
      fi
      if printf '%s' "$got" | grep -qx 'inventory'; then
        echo "  'inventory' is in your output. Its own duration_ms is 120; the 4200 belongs"
        echo "  to the nested upstream object, which is a different measurement."
      fi
      if printf '%s' "$got" | grep -qx 'email'; then
        echo "  'email' is in your output. Its duration_ms is exactly 500, and the rule is"
        echo "  strictly greater than 500."
      fi
      if ! printf '%s' "$got" | grep -qx 'order api'; then
        echo "  'order api' is missing. Its name contains a space — nothing about a JSON"
        echo "  string field says it cannot."
      fi
      if ! printf '%s' "$got" | grep -qx 'billing'; then
        echo "  'billing' is missing. That record lists its fields in a different order,"
        echo "  which is valid JSON and invisible to a pattern anchored on field position."
      fi
      exit 1
---
