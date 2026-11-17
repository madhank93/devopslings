---
kind: lesson
title: "All four keys improved, and the team ships less"
description: |
  Six weeks after a pipeline change, checkout's delivery dashboard is green on
  every key: deploys up nearly fourfold, lead time down, failures and recovery
  down. Fewer changes reached customers than in any six weeks before. Find
  the number that was pushed, and the signal that would have caught it.
name: gaming-the-numbers
slug: gaming-the-numbers
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
      work="$DEVOPSLINGS_ROOT/scratch/gaming-the-numbers"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- gamed \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      cat > "$work/dashboard.txt" <<'TXT'
      checkout — delivery dashboard                     Q3 (12 weeks)   Q4 so far (6 weeks)

      deployment frequency, per week                         2.3             8.0      better
      lead time for changes, median hours                   27.4            16.2      better
      change failure rate                                   14.3%            2.1%     better
      failed deployment recovery time, median minutes        140             110      better

      Q4 starts Monday 2026-09-28. How each number is computed:

        deployments     production deploy tags whose result is succeeded
        lead time       each commit on main, to the first production deploy after it
        change failure  incidents a change caused, over deployments
        recovery        from the failed deployment to the incident's resolution

      Q4 incidents: INC-107, 2026-10-15, invoice downloads timing out for every
      customer. Resolved 16:50 UTC by reverting the PDF invoices change.
      TXT

      cat > "$work/answer.txt" <<'TXT'
      # One of the dashboard's numbers was pushed up on purpose, and the others
      # moved with it. Find the lever and what it hides.

      # The metric that was gamed.
      gamed-metric=

      # How many Q4 production deployments changed nothing.
      noop-deploys=

      # Lead time for changes measured honestly — each commit to the first
      # deployment that actually carried it — median hours, before and after.
      lead-time-q3-hours=
      lead-time-q4-hours=

      # A measure you would add next to the dashboard that this could not have
      # moved, and why.
      counter-signal=
      TXT

      echo "scenario ready — eighteen weeks of checkout, and the dashboard the review is reading"
      echo
      echo "  $work/dashboard.txt"
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      ans="$DEVOPSLINGS_ROOT/scratch/gaming-the-numbers/answer.txt"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing — reset the lesson to put the template back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }
      num() { val "$1" | tr -d ' ,h' | grep -Eo '^[0-9]+(\.[0-9]+)?' || true; }
      near() { [ -n "$1" ] && awk -v g="$1" -v w="$2" 'BEGIN { exit !(g >= w * 0.95 && g <= w * 1.05) }'; }
      measure() {
        docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
          http://devops:devopslings@forge:3000/devops/checkout.git "$1" < "$module/files/metrics.sh"
      }
      q4=1790553600 # Mon 2026-09-28 00:00 UTC, the dashboard's quarter boundary

      deploys=$(measure deploys)
      if [ "$(printf '%s\n' "$deploys" | grep -c . || true)" -lt 40 ]; then
        echo "not yet: could not read checkout's eighteen weeks from the forge — reset the lesson."
        exit 1
      fi
      q4_deploys=$(printf '%s\n' "$deploys" | awk -v q="$q4" '$2 >= q' | grep -c . || true)
      want_noops=$(measure noops | grep -c . || true)
      # Median of the honest lead times for the deploys on one side of q4.
      leads=$(measure leadtimes)
      median() {
        printf '%s\n' "$deploys" | awk -v q="$q4" -v side="$1" '
          NR == FNR { if ((side == "q4") == ($2 >= q)) keep[$1] = 1; next }
          keep[$3] { print $2 / 3600 }' - <(printf '%s\n' "$leads") | sort -n |
          awk '{ v[NR] = $1 } END { printf "%.1f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
      }
      want_q3=$(median q3)
      want_q4=$(median q4)

      gamed=$(val gamed-metric | tr 'A-Z' 'a-z')
      if [ -z "$gamed" ]; then
        echo "not yet: gamed-metric= is empty."
        exit 1
      fi
      if ! printf '%s\n' "$gamed" | grep -Eq '\b(frequency|deploys? per|deployments? per|deploy count|number of deploy(ment)?s)\b'; then
        echo "not yet: gamed-metric=$(val gamed-metric), and that number moved because another one was pushed."
        if printf '%s\n' "$gamed" | grep -Eq '\b(failure|failures|cfr)\b'; then
          echo "         Change failure rate is failures over deployments. Q4 had one failure, as it would have"
          echo "         anyway; what changed is how many deployments it was divided by. Find out what they were."
        elif printf '%s\n' "$gamed" | grep -Eq '\b(lead)\b'; then
          echo "         The dashboard's lead time joins each commit to the next deploy by time. It fell because"
          echo "         there is now a deploy every night, whether it carries the commit or not. What put it there?"
        elif printf '%s\n' "$gamed" | grep -Eq '\b(recovery|fdrt|mttr|restore)\b'; then
          echo "         Recovery time in Q4 is one incident, fixed by a revert in under two hours. It is an"
          echo "         honest number. Look at what the pipeline started doing in week 13."
        else
          echo "         Compare Q3 and Q4 deploy tags: git tag -n9 'deploy/production/*' | grep trigger."
        fi
        exit 1
      fi

      noops=$(val noop-deploys | tr -dc '0-9')
      if [ "$noops" != "$want_noops" ]; then
        echo "not yet: noop-deploys=${noops:-<empty>}, and $want_noops of Q4's $q4_deploys deployments changed nothing."
        if [ "$noops" = "$q4_deploys" ]; then
          echo "         $noops is every Q4 deployment. Some of them did carry new commits: the Thursday train and"
          echo "         the revert."
        elif [ "$noops" = "$((q4_deploys - want_noops))" ]; then
          echo "         $noops is the deployments that did change something."
        else
          echo "         A deployment changed nothing when it deployed the same commit as the deployment before it."
        fi
        exit 1
      fi

      got_q3=$(num lead-time-q3-hours)
      got_q4=$(num lead-time-q4-hours)
      if ! near "$got_q3" "$want_q3" || ! near "$got_q4" "$want_q4"; then
        echo "not yet: lead-time-q3-hours=$(val lead-time-q3-hours), lead-time-q4-hours=$(val lead-time-q4-hours)."
        if near "$got_q4" 16.2 || near "$got_q3" 27.4; then
          echo "         Those are the dashboard's numbers: each commit to the next deploy after it. A nightly"
          echo "         redeploy of last week's commit is the next deploy after Monday's work, and carries none of it."
        else
          echo "         Time each commit from its commit date to the first successful production deploy whose"
          echo "         commit contains it, then take the median of the commits deployed in each quarter."
        fi
        exit 1
      fi

      counter=$(val counter-signal | tr 'A-Z' 'a-z')
      if [ -z "$counter" ]; then
        echo "not yet: counter-signal= is empty. Lead time per change went from $want_q3 to $want_q4 hours while the"
        echo "         dashboard improved. What would you put next to it so the next lever is visible?"
        exit 1
      fi
      if ! printf '%s\n' "$counter" | grep -Eq '\b(commits?|changes?|changed|carried|carries|carry|new code|per change)\b'; then
        echo "not yet: counter-signal=$(val counter-signal)"
        echo "         says nothing about what a deployment carried. A redeploy of an unchanged commit passes any"
        echo "         measure that only counts deploys; the counter-signal has to count changes delivered."
        exit 1
      fi

      echo "PASS — deployment frequency was the lever: $want_noops of $q4_deploys Q4 deployments redeployed what was already"
      echo "       running. Measured per change, lead time went from $want_q3 to $want_q4 hours."
---
