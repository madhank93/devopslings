---
kind: lesson
title: "A third of the CPU, in a line that never prints"
description: |
  The freight quoter needs a quarter more capacity before peak season. The team
  has optimised the promotions loop twice, because it is obviously the slow
  part. Profile it instead: a third of the CPU goes somewhere nobody looked.
  Name it from the profile, fix it, and measure the fix.
name: flame-graph
slug: flame-graph
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.flame-graph
      lesson=$1
      mkdir -p answers
      rm -f answers/flame-graph.txt answers/quote.folded
      cp "$lesson/files/quote.py" answers/quote.py

      echo "scenario ready — the quoter is answers/quote.py (in sandboxes/chaos-stack)."
      echo
      echo "Profile it (5 seconds; samples go to answers/quote.folded):"
      echo "  bash $lesson/files/profile.sh answers/quote.py"
      echo "Only the rate:"
      echo "  bash $lesson/files/profile.sh answers/quote.py 5 bench"

  verify_done:
    timeout_seconds: 180
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.flame-graph
      lesson=$1
      ans=answers/flame-graph.txt
      hot=$(grep -E '^hot_function=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' "' || true)
      if [ -z "$hot" ]; then
        echo "not yet: $ans needs hot_function=<name>: the function the profile shows taking about"
        echo "a third of the CPU, that nobody had suspected."
        exit 1
      fi
      if grep -qiE 'promotion' <<<"$hot"; then
        echo "not yet: hot_function=$hot. That is the step everyone already suspected, and the one"
        echo "doing the pricing the customer pays for. The other third of the samples is under a"
        echo "different child of quote.quote."
        exit 1
      fi
      if grep -qiE '(^|[.])(quote|run|<module>)$' <<<"$hot"; then
        echo "not yet: hot_function=$hot is in every sample: total% counts a frame and everything it"
        echo "calls, so the outermost frames are always near 100%. Follow the tree down to the"
        echo "children of quote.quote and compare them."
        exit 1
      fi
      if ! grep -qiE '(^|[^a-z])(dumps|encode|_?iterencode[a-z_]*|debug)$' <<<"$hot"; then
        echo "not yet: hot_function=$hot. Profile answers/quote.py with the lesson's profile.sh and read"
        echo "the children of quote.quote: one of them takes about a third of the samples."
        exit 1
      fi

      if [ ! -s answers/quote.py ]; then
        echo "not yet: answers/quote.py is missing. Rerun the init to get the original back."
        exit 1
      fi
      dir=/srv/flame-graph
      if ! bash "$lesson/files/profile.sh" answers/quote.py 1 bench >/dev/null 2>&1; then
        echo "not yet: answers/quote.py does not run:"
        docker compose exec -T -w "$dir" checkout timeout 30 python3 bench.py quote.py 0.1 2>&1 | tail -3
        exit 1
      fi
      c=$(docker compose exec -T -w "$dir" checkout timeout 60 python3 check.py original.py quote.py 2>&1 | tail -1)
      if [ "$(jq -r '.same_prices' <<<"$c" 2>/dev/null || true)" != true ]; then
        echo "not yet: answers/quote.py prices some orders differently from the original. The fix is to"
        echo "the cost of quoting, not to the quote. ($c)"
        exit 1
      fi
      if [ "$(jq -r '.debug_has_order' <<<"$c" 2>/dev/null || true)" != true ]; then
        echo "not yet: with LOG_LEVEL=DEBUG, quote() no longer logs the order it is quoting. Support turns"
        echo "DEBUG on to find out why a customer got a price; the line has to stay. What has to"
        echo "go is its cost when DEBUG is off."
        exit 1
      fi
      calls=$(jq -r '.dumps_at_info' <<<"$c" 2>/dev/null || echo 1)
      if [ "$calls" != 0 ]; then
        echo "not yet: with DEBUG off, quoting 200 orders still called json.dumps $calls times. The logger"
        echo "drops the message, but Python builds a call's arguments before the call: an f-string,"
        echo "or json.dumps(...) passed as an argument, runs whatever the level. Don't build the"
        echo "message unless the logger will use it."
        exit 1
      fi

      b0=$(docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py original.py 3 2>/dev/null | jq -r '.quotes_per_s' 2>/dev/null || true)
      b1=$(docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py quote.py 3 2>/dev/null | jq -r '.quotes_per_s' 2>/dev/null || true)
      if [ -z "$b0" ] || [ -z "$b1" ]; then
        echo "not yet: the benchmark did not finish. Run profile.sh yourself and read what it says."
        exit 1
      fi
      echo "this check benchmarked both, 3 seconds each: original $b0 quotes/s, answers/quote.py $b1 quotes/s"
      if [ "$b1" -lt "$(awk -v b="$b0" 'BEGIN { printf "%d", 1.25 * b }')" ]; then
        echo "not yet: $b1 against $b0 quotes a second is not the quarter more capacity the season needs"
        echo "(at least 1.25 times). Profile answers/quote.py again and see what is left."
        exit 1
      fi
      echo "PASS — $hot was a third of the CPU; quoting now runs $b1 a second against $b0, prices"
      echo "unchanged, and the DEBUG line is still there when it is switched on."
---
