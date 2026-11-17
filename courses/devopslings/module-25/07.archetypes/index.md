---
kind: lesson
title: "Where does this team actually sit?"
description: |
  A different team, the same service: one release train a week, on
  Wednesdays. Their manager calls them "Low performers, by the old chart".
  DORA retired that chart in 2025 for seven team archetypes. Place the team
  in one, from their delivery history and their survey, and show the numbers.
name: archetypes
slug: archetypes
createdAt: "2026-11-16"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      work="$DEVOPSLINGS_ROOT/scratch/archetypes"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- methodical \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      cat > "$work/profiles.md" <<'MD'
      # The seven team archetypes (DORA 2025), as this platform team reads them

      DORA clusters teams on throughput, instability, and how the team and
      its product are doing. The bands below are the platform team's, so that
      two people placing the same team get the same answer.

      Throughput    high: 5 or more production deployments a week, and a median
                          lead time for changes under 24 hours
                    low:  fewer than 2 a week, or a median lead time over 48 hours
      Instability   low:  rework rate under 10%
                    high: rework rate over 15%
      Survey        friction, burnout and product performance, low or high

      | archetype                 | throughput | instability | survey                                   |
      |---------------------------|------------|-------------|------------------------------------------|
      | Foundational challenges   | low        | high        | friction high, burnout high, product low |
      | The legacy bottleneck     | low        | high        | burnout high, product low                |
      | Constrained by process    | low        | low         | friction high, burnout high              |
      | High impact, low cadence  | low        | high        | product high                             |
      | Stable and methodical     | low        | low         | friction low, burnout low, product high  |
      | Pragmatic performers      | high       | low         | burnout and product middling             |
      | Harmonious high-achievers | high       | low         | friction low, burnout low, product high  |
      MD

      cat > "$work/team-survey.txt" <<'TXT'
      checkout team, quarterly survey, 1 (low) to 5 (high), n=7

      friction in day-to-day work          1.9   low
      burnout                              1.7   low
      product performance (self-reported)  4.2   high
      time on valuable work                4.0   high
      TXT

      cat > "$work/answer.txt" <<'TXT'
      # Place the team in one of the seven archetypes in profiles.md, from
      # the production history on the forge and team-survey.txt.

      # Production deployments per week, over the twelve weeks.
      deploys-per-week=

      # Lead time for changes, median hours, each commit to the deploy that
      # first carried it.
      lead-time-median-hours=

      # Rework rate, percent of production deployments.
      rework-rate=

      # One of the seven, by name.
      archetype=
      TXT

      echo "scenario ready — twelve weeks of a Wednesday-only release train"
      echo
      echo "  $work/profiles.md"
      echo "  $work/team-survey.txt"
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      ans="$DEVOPSLINGS_ROOT/scratch/archetypes/answer.txt"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing — reset the lesson to put the template back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }
      num() { val "$1" | tr -d ' ,h%' | grep -Eo '^[0-9]*\.?[0-9]+' || true; }
      within() { [ -n "$1" ] && awk -v g="$1" -v w="$2" -v t="$3" 'BEGIN { d = g - w; exit !(d <= t && d >= -t) }'; }
      measure() {
        docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
          http://devops:devopslings@forge:3000/devops/checkout.git "$1" < "$module/files/metrics.sh"
      }

      deploys=$(measure deploys | grep -c . || true)
      if [ "$deploys" -lt 5 ]; then
        echo "not yet: could not read the team's deploy history from the forge — reset the lesson."
        exit 1
      fi
      want_freq=$(awk -v d="$deploys" 'BEGIN { printf "%.2f", d / 12 }')
      stats=$(measure leadstats)
      p50=$(printf '%s\n' "$stats" | awk '$1 == "p50" { print $3 }')
      rework=$(measure rework | grep -c . || true)
      want_rework=$(awk -v r="$rework" -v d="$deploys" 'BEGIN { printf "%.1f", 100 * r / d }')

      freq=$(num deploys-per-week)
      if [ -z "$freq" ]; then
        echo "not yet: deploys-per-week= is empty or not a number. Start with the throughput: count, then divide."
        exit 1
      fi
      if ! within "$freq" "$want_freq" 0.15; then
        echo "not yet: deploys-per-week=$(val deploys-per-week), and the team made $deploys production deployments in twelve weeks."
        tags=$(git ls-remote --tags http://devops:devopslings@127.0.0.1:3000/devops/checkout.git 2>/dev/null | grep -v '\^{}' || true)
        all=$(printf '%s\n' "$tags" | grep -c 'refs/tags/deploy/' || true)
        if [ -n "$freq" ] && within "$freq" "$(awk -v a="$all" 'BEGIN { print a / 12 }')" 0.15; then
          echo "         That counts deploy/staging tags. Throughput is about production."
        else
          echo "         Count the deploy/production tags whose result is succeeded, over twelve weeks."
        fi
        exit 1
      fi
      lead=$(num lead-time-median-hours)
      if [ -z "$lead" ] || ! awk -v g="$lead" -v w="$p50" 'BEGIN { exit !(g >= w * 0.95 && g <= w * 1.05) }'; then
        echo "not yet: lead-time-median-hours=$(val lead-time-median-hours), and the median over every deployed commit is $p50 hours."
        head=$(printf '%s\n' "$stats" | awk '$1 == "head-p50" { print $3 }')
        if [ -n "$lead" ] && awk -v g="$lead" -v w="$head" 'BEGIN { exit !(g >= w * 0.9 && g <= w * 1.1) }'; then
          echo "         $lead hours is each deploy's newest commit. A weekly train makes the rest of the week's"
          echo "         commits wait for it — measure every commit, as in lead-time."
        else
          echo "         Time each commit to the first successful production deploy that carried it."
        fi
        exit 1
      fi
      rr=$(num rework-rate)
      if [ -n "$rr" ] && awk -v c="$rr" 'BEGIN { exit !(c > 0 && c < 1) }'; then
        rr=$(awk -v c="$rr" 'BEGIN { printf "%.2f", c * 100 }')
      fi
      if ! within "$rr" "$want_rework" 0.5; then
        echo "not yet: rework-rate=$(val rework-rate), and $rework of the $deploys production deployments were rework: $want_rework%."
        echo "         Use rework-rate's definition: a deployment that fixed or reverted a change already in production."
        exit 1
      fi

      a=$(val archetype | tr 'A-Z' 'a-z')
      case "$a" in
        *stable*methodical*) ;;
        "")
          echo "not yet: the numbers are right, and archetype= is empty."
          exit 1 ;;
        *elite*|*high\ perform*|*medium*|*low\ perform*|low|high)
          echo "not yet: archetype=$(val archetype). Elite, High, Medium and Low were retired in 2025. On that"
          echo "         chart, one deploy a week is Low and nothing else about this team counts. Use profiles.md."
          exit 1 ;;
        *harmonious*|*pragmatic*)
          echo "not yet: archetype=$(val archetype) needs high throughput. $want_freq deploys a week and a $p50-hour median"
          echo "         lead time are low by profiles.md's bands."
          exit 1 ;;
        *foundational*|*legacy*|*high\ impact*|*cadence*)
          echo "not yet: archetype=$(val archetype) needs high instability, and rework is $want_rework% — under 10%."
          echo "         One revert in twelve weeks is a team that rarely breaks production."
          exit 1 ;;
        *constrained*|*process*)
          echo "not yet: archetype=$(val archetype). Throughput is low and instability is low, so far so good, and that"
          echo "         profile is a team ground down by its process: friction and burnout high. Read team-survey.txt."
          exit 1 ;;
        *)
          echo "not yet: archetype=$(val archetype) is not one of the seven in profiles.md."
          exit 1 ;;
      esac

      echo "PASS — Stable and methodical: $want_freq deploys a week, a $p50-hour median lead time, $want_rework% rework,"
      echo "       and a team that is not burning out. Slow is a choice here, not a symptom."
---
