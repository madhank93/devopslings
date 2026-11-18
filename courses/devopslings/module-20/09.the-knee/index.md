---
kind: lesson
title: "The ninth node made it slower"
description: |
  The ledger posts entries from a queue. At four nodes it kept up. At six it
  stopped getting faster, and the ninth node made it slower. The plan is to go
  to sixteen. Find what every node is waiting for, and make nine nodes do
  more than five ever did.
name: the-knee
slug: the-knee
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.the-knee
      lesson=$1
      # .env lives outside any container, so a solved attempt would otherwise stay solved.
      echo "NODES=9" > .env
      mkdir -p answers
      rm -f answers/the-knee.txt
      cp "$lesson/files/ledger.py" answers/ledger.py
      # The original code's throughput at each node count, on this machine: the
      # check compares the fix with it rather than with a fixed number.
      bash "$lesson/files/bench.sh" "$lesson/files/ledger.py" 1 2 3 4 5 6 7 8 9 10 12 > /tmp/the-knee-baseline.json 2>/dev/null || true
      docker compose cp /tmp/the-knee-baseline.json checkout:/srv/the-knee/baseline.json >/dev/null 2>&1 || true
      rm -f /tmp/the-knee-baseline.json

      echo "scenario ready — the ledger code is answers/ledger.py; NODES=9 in sandboxes/chaos-stack/.env."
      echo
      echo "Measure it at any node counts (4 seconds each):"
      echo "  bash $lesson/files/bench.sh answers/ledger.py 1 2 4 6 9"
      echo
      echo "Shared code the nodes call, not yours to change: $lesson/files/store.py"

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.the-knee
      lesson=$1
      ans=answers/the-knee.txt
      base=$(docker compose exec -T checkout cat /srv/the-knee/baseline.json 2>/dev/null | jq -sc . 2>/dev/null || true)
      if [ "$(jq 'length' <<<"${base:-[]}" 2>/dev/null || echo 0)" -lt 5 ]; then
        echo "not yet: the baseline measurement from the lesson's init is missing — rerun the init."
        exit 1
      fi
      best=$(jq 'max_by(.entries_per_s) | .entries_per_s' <<<"$base")
      bestn=$(jq 'max_by(.entries_per_s) | .nodes' <<<"$base")

      peak=$(grep -E '^peak_nodes=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9' || true)
      if [ -z "$peak" ]; then
        echo "not yet: $ans needs peak_nodes=<n>: the node count at which the original code's"
        echo "throughput was highest. Measure it with the lesson's bench.sh before you change anything."
        exit 1
      fi
      at=$(jq --argjson n "$peak" '[.[] | select(.nodes == $n) | .entries_per_s][0] // 0' <<<"$base")
      if awk -v a="$at" -v b="$best" 'BEGIN { exit !(a < 0.93 * b) }'; then
        echo "not yet: peak_nodes=$peak. When the lesson started, this machine measured the original code"
        echo "at $(jq -r 'map("\(.nodes)→\(.entries_per_s)") | join(" ")' <<<"$base") entries/s (nodes→rate);"
        echo "the highest is at $bestn nodes."
        exit 1
      fi

      nodes=$(grep -E '^NODES=' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9' || true)
      nodes=${nodes:-9}
      if [ "$nodes" -gt 9 ]; then
        echo "not yet: NODES=$nodes. Past $bestn nodes every node you add made the ledger slower — the"
        echo "nodes are queueing for something, and more of them make a longer queue. The fix has to"
        echo "come from nine nodes or fewer."
        exit 1
      fi
      r=$(bash "$lesson/files/bench.sh" answers/ledger.py "$nodes" 2>&1 | tail -1)
      rate=$(jq -r '.entries_per_s // empty' <<<"$r" 2>/dev/null || true)
      lost=$(jq -r '.lost // empty' <<<"$r" 2>/dev/null || true)
      if [ -z "$rate" ]; then
        echo "not yet: answers/ledger.py did not run:"
        echo "$r" | tail -3
        exit 1
      fi
      echo "this check measured answers/ledger.py at $nodes nodes: $rate entries/s, $lost cents lost (the original peaked at $best entries/s)"
      if [ "$lost" != 0 ]; then
        echo "not yet: the balance is off by $lost cents. Two nodes read the same balance, each added"
        echo "its entry, and the second write erased the first. The read and the write of the row"
        echo "have to stay under the lock; the question is what else does."
        exit 1
      fi
      if [ "$rate" -lt "$(awk -v b="$best" 'BEGIN { printf "%d", 1.4 * b }')" ]; then
        echo "not yet: $rate entries/s at $nodes nodes is not past the original peak of $best by enough."
        echo "Fewer nodes only gets back to the peak: the ceiling is how long each post holds"
        echo "ledger_lock, because only one node can hold it. Look at what post() does while it holds"
        echo "it, and which of those steps touch the balance."
        exit 1
      fi
      echo "PASS — the original peaked at $best entries/s at $bestn nodes; $nodes nodes now post $rate, none lost."
---
