---
kind: lesson
title: "Rework rate: which deploys were fixing the last one?"
description: |
  DORA added a fifth metric for the deploys nobody planned: the ones made
  because something already in production was broken. The commit history
  holds the evidence, and most of what says "fix" in it is not that. Find the
  rework deployments, and only those.
name: rework-rate
slug: rework-rate
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
      work="$DEVOPSLINGS_ROOT/scratch/rework-rate"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- base \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      cat > "$work/answer.txt" <<'TXT'
      # Rework: production deployments that were unplanned, and made to fix
      # something that was already broken in production.

      # The rework deployments' tags (or run numbers), comma-separated.
      rework-deploys=

      # Rework deployments as a percentage of all production deployments.
      rework-rate=
      TXT

      echo "scenario ready — the same twelve weeks of checkout"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      ans="$DEVOPSLINGS_ROOT/scratch/rework-rate/answer.txt"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing — reset the lesson to put the template back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }
      measure() {
        docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
          http://devops:devopslings@forge:3000/devops/checkout.git "$1" < "$module/files/metrics.sh"
      }

      deploys=$(measure deploys)
      total=$(printf '%s\n' "$deploys" | grep -c . || true)
      if [ "$total" -lt 10 ]; then
        echo "not yet: could not read checkout's deploy history from the forge — reset the lesson."
        exit 1
      fi
      want=$(measure rework | sed 's|.*/||' | sort -n | tr '\n' ' ')
      got=$(val rework-deploys | grep -Eo '[0-9]+' | sort -nu | tr '\n' ' ' || true)
      if [ -z "$got" ]; then
        echo "not yet: rework-deploys= is empty."
        exit 1
      fi

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r" 2>/dev/null

      # Explain the first wrong entry, in either direction.
      for r in $got; do
        case " $want " in *" $r "*) continue ;; esac
        tag=deploy/production/$r
        row=$(printf '%s\n' "$deploys" | awk -v t="$tag" '$1 == t')
        echo "not yet: $tag is in rework-deploys=, and it is not a rework deployment."
        if [ -z "$row" ]; then
          if git -C "$work/r" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            echo "         It did not reach production — read its result line. A deploy that changed nothing"
            echo "         reworked nothing."
          else
            echo "         There is no such production deploy."
          fi
          exit 1
        fi
        trigger=$(printf '%s\n' "$row" | awk '{ print $4 }')
        target=$(printf '%s\n' "$row" | awk '{ print $3 }')
        prev=$(printf '%s\n' "$deploys" | awk -v t="$tag" '$1 == t { print p; exit } { p = $3 }')
        if [ "$trigger" = release-train ]; then
          if git -C "$work/r" log --format=%b "$target" ${prev:+"^$prev"} | grep '^Fixes: ' >/dev/null; then
            echo "         It carries a commit with a Fixes: trailer — and the commit that trailer names had not"
            echo "         reached production when the fix did. A bug caught before it shipped is not rework."
          else
            echo "         It is the scheduled release train. It may carry commits that say \"fix\", and the"
            echo "         deployment was planned: rework is a deployment made because production was broken."
          fi
        elif git -C "$work/r" log --format=%b "$target" ${prev:+"^$prev"} | grep -E '^(Fixes: |This reverts commit )' >/dev/null; then
          echo "         It was off the release train, and what it fixes had not reached production before it."
        else
          echo "         It was off the release train, and nothing it carried fixes or reverts anything. Read the"
          echo "         deploy before it: a retry of an aborted attempt, or a launch somebody planned for a"
          echo "         Friday morning, is unplanned only in the sense of not being on a Tuesday."
        fi
        exit 1
      done
      for r in $want; do
        case " $got " in *" $r "*) continue ;; esac
        tag=deploy/production/$r
        echo "not yet: rework-deploys= is missing $tag."
        row=$(printf '%s\n' "$deploys" | awk -v t="$tag" '$1 == t')
        target=$(printf '%s\n' "$row" | awk '{ print $3 }')
        prev=$(printf '%s\n' "$deploys" | awk -v t="$tag" '$1 == t { print p; exit } { p = $3 }')
        if git -C "$work/r" log --format=%B "$target" ${prev:+"^$prev"} | grep -E '\bINC-[0-9]+' >/dev/null; then
          echo "         Read the commits it carried that the deploy before it did not."
        else
          echo "         No incident was filed for it. Customers reported the bug against a change that was in"
          echo "         production, and this deployment went out off the train to fix it. Rework is about the"
          echo "         deployment, not about whether somebody opened a ticket — which is exactly why it"
          echo "         finds work that change failure rate does not."
        fi
        exit 1
      done

      n=$(printf '%s\n' $want | grep -c . || true)
      rate=$(awk -v n="$n" -v d="$total" 'BEGIN { printf "%.1f", 100 * n / d }')
      g=$(val rework-rate | tr -d ' %' | grep -Eo '^[0-9]+(\.[0-9]+)?' || true)
      if [ -n "$g" ] && awk -v c="$g" 'BEGIN { exit !(c > 0 && c < 1) }'; then
        g=$(awk -v c="$g" 'BEGIN { printf "%.2f", c * 100 }')
      fi
      if [ -z "$g" ] || ! awk -v g="$g" -v w="$rate" 'BEGIN { d = g - w; exit !(d < 0.5 && d > -0.5) }'; then
        echo "not yet: the deployments are right, and rework-rate=$(val rework-rate) is not $n of $total: $rate%."
        exit 1
      fi

      echo "PASS — $n of $total deployments were rework ($rate%). Change failure rate saw four of them; the fifth"
      echo "       was a bug customers found, fixed off the train, with no incident attached."
---
