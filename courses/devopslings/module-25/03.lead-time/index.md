---
kind: lesson
title: "Lead time for changes, measured from every commit"
description: |
  The dashboard says checkout's lead time is about three and a half hours. It
  measured each deploy from the newest commit in it, which is the one commit
  guaranteed to have waited least. Measure every change from its commit to the
  production deploy that carried it, and report the distribution, not a number.
name: lead-time
slug: lead-time
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
      work="$DEVOPSLINGS_ROOT/scratch/lead-time"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- base \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      cat > "$work/answer.txt" <<'TXT'
      # Lead time for changes: from a commit to the production deploy that
      # first carried it, for every commit that has reached production.
      # Hours may have decimals.

      # How many commits you measured.
      commits=

      median-hours=

      # 90th percentile.
      p90-hours=

      # The deploy tag that carried the commits that waited longest.
      slowest-deploy=
      TXT

      echo "scenario ready — the same twelve weeks of checkout as count-your-deploys"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      ans="$DEVOPSLINGS_ROOT/scratch/lead-time/answer.txt"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing — reset the lesson to put the template back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }
      num() { val "$1" | tr -d ' ,h' | grep -Eo '^[0-9]+(\.[0-9]+)?' || true; }
      measure() {
        docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
          http://devops:devopslings@forge:3000/devops/checkout.git "$1" < "$module/files/metrics.sh"
      }

      stats=$(measure leadstats)
      stat() { printf '%s\n' "$stats" | awk -v k="$1" -v f="$2" '$1 == k { print $f }'; }
      n=$(stat n 2)
      if [ -z "$n" ] || [ "$n" -lt 50 ]; then
        echo "not yet: could not read checkout's history from the forge — reset the lesson."
        exit 1
      fi
      # Either percentile convention is right; the band covers both.
      within() { awk -v g="$1" -v a="$2" -v b="$3" 'BEGIN { lo = (a < b ? a : b) * 0.95; hi = (a > b ? a : b) * 1.05; exit !(g >= lo && g <= hi) }'; }

      commits=$(val commits | tr -dc '0-9')
      if [ "$commits" != "$n" ]; then
        heads=$(stat heads 2)
        echo "not yet: commits=${commits:-<empty>}, and $n commits have reached production in this history."
        if [ "$commits" = "$heads" ]; then
          echo "         $heads is one commit per deploy. A deploy carries every commit since the previous one,"
          echo "         and each of them has its own lead time — the newest one is just the one that waited least."
        else
          echo "         Count the commits each successful production deploy carried for the first time:"
          echo "         git rev-list <this deploy's commit> ^<previous deploy's commit>. Commits after the last"
          echo "         deploy have no lead time yet, and staging or aborted deploys shipped nothing."
        fi
        exit 1
      fi

      median=$(num median-hours)
      if [ -z "$median" ]; then
        echo "not yet: median-hours= is empty or not a number."
        exit 1
      fi
      if ! within "$median" "$(stat p50 2)" "$(stat p50 3)"; then
        echo "not yet: median-hours=$median, and the median over those $n commits is $(stat p50 3) hours."
        if within "$median" "$(stat mean 2)" "$(stat mean 2)"; then
          echo "         $median is the mean. One bad week drags a mean a long way; that is the reason to"
          echo "         report the median and a high percentile instead."
        elif within "$median" "$(stat head-p50 2)" "$(stat head-p50 3)"; then
          echo "         That is the median of each deploy's newest commit — the dashboard's number."
        else
          echo "         Time each commit from its committer date to the tagger date of the deploy that"
          echo "         first carried it."
        fi
        exit 1
      fi

      p90=$(num p90-hours)
      if [ -z "$p90" ]; then
        echo "not yet: the median is right, and p90-hours= is empty. Half of all changes wait longer than"
        echo "         $median hours, and the median says nothing about how much longer."
        exit 1
      fi
      if ! within "$p90" "$(stat p90 2)" "$(stat p90 3)"; then
        echo "not yet: p90-hours=$p90, and the 90th percentile of the $n lead times is $(stat p90 3) hours."
        exit 1
      fi

      slowest=$(measure leadtimes | sort -k2 -n | tail -1 | awk '{ print $3 }')
      got=$(val slowest-deploy | grep -Eo '[0-9]+' | tail -1 || true)
      if [ "${slowest##*/}" != "$got" ]; then
        echo "not yet: slowest-deploy=$(val slowest-deploy). Find the commits with the longest lead times and"
        echo "         the deploy that finally carried them, then read what happened to the release train"
        echo "         in the week before it."
        exit 1
      fi

      echo "PASS — $n commits: median $median h, p90 $p90 h. The tail is $slowest, the first deploy after"
      echo "       the change freeze — a median of a day hides commits that waited eleven."
---
