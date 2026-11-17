---
kind: lesson
title: "Error budget policy"
description: |
  Checkout's 28-day error budget ran out in week two, and the team carried
  on shipping features, because nothing said they should not. Write the
  policy that says what stops, who decides the exceptions and what ends it
  — and make the one consequence the team controls actually happen.
name: error-budget-policy
slug: error-budget-policy
createdAt: "2026-11-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      g=/var/lib/devopslings/ebp
      mkdir -p "$g" /ha/sre/slo
      cat > "$g/window.py" <<'PY'
      # window.py REMAINING_PERCENT — 14 days of checkout's SLI, spending the
      # budget down to that much left (negative when overspent).
      import sys
      left = float(sys.argv[1]) / 100
      valid = [118000 + 900 * (d % 7) for d in range(14)]
      bad_total = (1 - left) * 0.005 * sum(valid)
      share = [1, 1, 1, 1, 1, 1, 1, 1, 30, 40, 2, 1, 1, 1]
      print("day,valid,good")
      for d, (v, s) in enumerate(zip(valid, share)):
          print(f"2026-11-{d + 1:02d},{v},{v - round(bad_total * s / sum(share))}")
      PY
      python3 "$g/window.py" -18 > /ha/sre/slo/window.csv
      cat > /ha/sre/budget <<'SH'
      #!/bin/bash
      # budget [--remaining] — checkout's error budget: SLO 99.5% of requests
      # good, over the window in /ha/sre/slo/window.csv. With --remaining, only
      # the percentage of the budget left (negative when overspent).
      set -eu
      awk -F, -v bare="${1:-}" 'NR > 1 { v += $2; g += $3 }
        END { b = v * 0.005; r = (b - (v - g)) / b * 100
              if (bare == "--remaining") { printf "%.1f\n", r; exit }
              printf "window:     %d days, %d requests\nbudget:     %d failed requests\nspent:      %d\nremaining:  %.1f%%\n", NR - 1, v, b, v - g, r }' /ha/sre/slo/window.csv
      SH
      cat > /ha/sre/deploy <<'SH'
      #!/bin/bash
      # deploy <build> <feature|fix> — ship a checkout build. Every deploy is logged.
      set -eu
      build=${1:?usage: deploy <build> <feature|fix>}
      kind=${2:?usage: deploy <build> <feature|fix>}
      case $kind in feature|fix) ;; *) echo "deploy: kind is feature or fix" >&2; exit 2 ;; esac
      echo "deploying $build ($kind)..."
      sleep 1
      echo "$(date -u +%FT%TZ) $build $kind" >> /ha/sre/deploys.log
      echo "done: $build is live"
      SH
      chmod +x /ha/sre/budget /ha/sre/deploy
      cat > /ha/sre/deploys.log <<'LOG'
      2026-11-10T09:12:44Z ranker-v3 feature
      2026-11-10T15:40:02Z gift-cards feature
      2026-11-11T10:05:31Z saved-carts feature
      2026-11-12T11:20:18Z ranker-v3.1 fix
      2026-11-13T14:02:55Z one-click feature
      2026-11-14T09:47:10Z wishlist-share feature
      LOG
      cat > /ha/sre/team.txt <<'TXT'
      # The checkout team, who wrote and own this policy.
      erin    tech lead
      farid   product manager
      bob     SRE, on the checkout on-call rota
      gita    engineer

      # Not on the team.
      dan     engineering manager for checkout, search and accounts
      ivy     VP engineering
      kai     release manager; owns the company release calendar

      # What the team controls: its own deploys (/ha/sre/deploy), its backlog
      # and sprint priorities, its on-call rota, its feature flags.
      # What it does not: other teams' deploys, the company release calendar,
      # hiring, the payment provider.
      TXT
      cat > /ha/answers/policy.txt <<'TXT'
      # Checkout's error budget policy. '#' starts a comment.
      applies_when: ?   # the measurable condition that puts it in force
      stops: ?          # what stops while it is in force
      continues: ?      # what still goes out
      decides: ?        # who grants an exception: one person, by name, from /ha/sre/team.txt
      unblocks: ?       # the measurable condition that ends it
      TXT
      echo "scenario ready — day 14 of checkout's 28-day window."
      echo
      /ha/sre/budget | sed 's/^/  /'
      echo
      echo "  what shipped anyway:  /ha/sre/deploys.log"
      echo "  the team:             /ha/sre/team.txt"
      echo "  the deploy tool:      /ha/sre/deploy <build> <feature|fix>"
      echo "  your policy:          /ha/answers/policy.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      g=/var/lib/devopslings/ebp
      a=/ha/answers/policy.txt
      if [ ! -f "$g/window.py" ]; then
        echo "not yet: the scenario's files are missing. Reset the lesson."
        exit 1
      fi
      field() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | sed 's/[[:space:]]*#.*//' | head -1 || true; }
      pct() { grep -oE -- '-?[0-9]+(\.[0-9]+)?' <<<"$1" | head -1 || true; }
      for k in applies_when stops continues decides unblocks; do
        v=$(field "$k")
        if [ -z "$v" ] || [ "$v" = "?" ]; then
          echo "not yet: $k in $a is not filled in."
          exit 1
        fi
      done

      # Who decides: one person the team can reach today.
      d=$(field decides | tr 'A-Z' 'a-z')
      names=$(grep -oE '\b(erin|farid|bob|gita|dan|ivy|kai)\b' <<<"$d" | sort -u || true)
      case $(printf '%s\n' "$names" | grep -c . || true) in
        0) echo "not yet: decides is '$d'. Name one person from /ha/sre/team.txt."
           echo "         'The team', or a role nobody holds by name, is how an exception gets granted by"
           echo "         whoever asks loudest."
           exit 1 ;;
        1) ;;
        *) echo "not yet: decides names $(echo $names | tr ' ' ','). One person decides; two people can decide"
           echo "         differently, and then nobody has."
           exit 1 ;;
      esac
      case $names in dan|ivy|kai)
        echo "not yet: decides is $names, who is not on the checkout team. A policy the team wrote and whose"
        echo "         exceptions someone else grants is not the team's to enforce: when $names is busy, the"
        echo "         choice is wait or ignore it. Pick the team's own decider; escalation can come later."
        exit 1 ;;
      esac

      # What stops: only things the checkout team controls.
      s=$(field stops)
      if out=$(grep -oiE "company|org(anisation|anization)?-?wide|all teams|every team|other teams|release calendar|hiring|provider|search|accounts" <<<"$s" | head -1) && [ -n "$out" ]; then
        echo "not yet: stops says '$s'."
        echo "         The checkout team does not control '$out' (team.txt): a consequence it cannot"
        echo "         carry out itself is a wish. Stop what the team ships."
        exit 1
      fi

      A=$(pct "$(field applies_when)")
      U=$(pct "$(field unblocks)")
      for k in applies_when unblocks; do
        v=$(field "$k")
        if [ -z "$(pct "$v")" ]; then
          echo "not yet: $k is '$v'."
          echo "         It needs a number someone can check: how much of the budget is left, as"
          echo "         /ha/sre/budget reports it. A condition without one ends whenever someone wants it to."
          exit 1
        fi
      done

      # The policy in force: the grader sets the budget and uses the team's own deploy tool.
      cp /ha/sre/slo/window.csv "$g/window.saved"
      cp /ha/sre/deploys.log "$g/deploys.saved"
      restore() { cp "$g/window.saved" /ha/sre/slo/window.csv; cp "$g/deploys.saved" /ha/sre/deploys.log; }
      trap restore EXIT
      at() { python3 "$g/window.py" "$1" > /ha/sre/slo/window.csv; }
      try() {  # try <kind> — 0 when the deploy happened
        local b="grader-$RANDOM-$1"
        timeout 30 /ha/sre/deploy "$b" "$1" > "$g/out" 2>&1 || true
        grep -q " $b $1\$" /ha/sre/deploys.log
      }
      left() { /ha/sre/budget --remaining; }

      at -18
      if try feature; then
        echo "not yet: with $(left)% of the budget left, '/ha/sre/deploy <build> feature' went out. The policy"
        echo "         says features stop; nothing stops them. A policy the deploy tool does not know about"
        echo "         is the situation you started with."
        exit 1
      fi
      if ! try fix; then
        echo "not yet: with the budget spent, the grader's fix deploy was refused too:"
        sed 's/^/         | /' "$g/out" | tail -3
        echo "         Fixes are how the budget stops burning. A policy that stops them stops the way out."
        exit 1
      fi
      echo "budget spent ($(left)%): features refused, fixes go out"

      hi=$(awk -v a="$A" -v u="$U" 'BEGIN { m = a > u ? a : u; print (m < 0 ? 0 : m) + 10 }')
      at "$hi"
      if ! try feature; then
        echo "not yet: with $(left)% of the budget left, past what unblocks says ($U%), the feature deploy"
        echo "         was still refused:"
        sed 's/^/         | /' "$g/out" | tail -3
        echo "         The gate has to read the budget, and let go at the condition the policy states."
        exit 1
      fi
      echo "budget back ($(left)%): features go out again"
      echo
      echo "PASS — the policy names what stops, who decides and what ends it, and the deploy tool enforces it."
---
