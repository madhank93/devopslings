---
kind: lesson
title: "Six incidents, and not all of them were your deploys"
description: |
  The quarter's incident log has six entries, and every one has a suspected
  deploy filled in by whoever was on call at 2am. Change failure rate and
  Failed Deployment Recovery Time count failures a change caused. A power cut
  in the datacentre is an incident, and it is not one of those.
name: change-failure-and-fdrt
slug: change-failure-and-fdrt
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
      work="$DEVOPSLINGS_ROOT/scratch/change-failure-and-fdrt"

      docker compose -p devopslings-ci-stack exec -T sops sh -s -- base \
        http://devops:devopslings@forge:3000/devops/checkout.git < "$module/files/seed.sh"

      rm -rf "$work"
      mkdir -p "$work"
      # The export from the incident tracker. suspected_deploy is what on-call
      # wrote when the page fired: the last production deploy, every time.
      cat > "$work/incidents.csv" <<'CSV'
      id,detected_at,resolved_at,severity,suspected_deploy,summary,resolution
      INC-101,2026-07-16T15:40Z,2026-07-16T16:52Z,SEV2,deploy/production/413,"Order totals off by one cent on multi-item orders","Reverted the line-item rounding change and redeployed (deploy/production/414)"
      INC-102,2026-07-29T02:10Z,2026-07-29T11:25Z,SEV1,deploy/production/425,"Checkout down: both app hosts unreachable","Power loss in hall B of the colo. Hosts came back when the facility restored the feed; nothing was rolled back or redeployed"
      INC-103,2026-08-14T09:20Z,2026-08-14T10:55Z,SEV2,deploy/production/443,"Customers see stale cart totals after removing items","Fixed cache invalidation and redeployed (deploy/production/444)"
      INC-104,2026-08-19T14:00Z,2026-08-19T16:30Z,SEV2,deploy/production/444,"Card authorisations failing with 503","Payment provider incident, on their status page. Recovered on their side; nothing deployed"
      INC-105,2026-09-15T15:25Z,2026-09-15T17:35Z,SEV3,deploy/production/477,"New address form rejects postcodes containing a space","Fixed the validation and redeployed (deploy/production/478)"
      INC-106,2026-09-24T16:10Z,2026-09-24T17:05Z,SEV1,deploy/production/488,"3-D Secure card payments failing","Reverted the payment-sdk bump and redeployed (deploy/production/489)"
      CSV

      cat > "$work/answer.txt" <<'TXT'
      # The quarter's change failure rate and Failed Deployment Recovery Time,
      # from incidents.csv and the deploy tags on the forge.

      # Incident ids that do not count towards either metric, comma-separated.
      excluded=

      # Failed deployments as a percentage of production deployments.
      change-failure-rate=

      # Median, in minutes, from the deployment that failed to the incident's
      # resolution.
      recovery-median-minutes=
      TXT

      echo "scenario ready — the quarter's incidents, and the same twelve weeks of deploys"
      echo
      echo "  $work/incidents.csv"
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  your answer:  $work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      module="$DEVOPSLINGS_ROOT/courses/devopslings/module-25"
      work="$DEVOPSLINGS_ROOT/scratch/change-failure-and-fdrt"
      ans="$work/answer.txt"
      if [ ! -s "$ans" ] || [ ! -s "$work/incidents.csv" ]; then
        echo "not yet: $work is missing its files — reset the lesson to put them back."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ans" | tail -1; }
      num() { val "$1" | tr -d ' ,%' | grep -Eo '^[0-9]+(\.[0-9]+)?' || true; }
      measure() {
        docker compose -p devopslings-ci-stack exec -T sops sh -s -- \
          http://devops:devopslings@forge:3000/devops/checkout.git "$@" < "$module/files/metrics.sh"
      }

      # Which incidents a change caused is a fact about this quarter, so it is
      # stated here; everything numeric is recomputed from the forge.
      change_caused="INC-101 INC-103 INC-105 INC-106"

      got=$(val excluded | tr 'a-z' 'A-Z' | grep -Eo 'INC-[0-9]+' | sort -u | tr '\n' ' ' || true)
      for id in INC-102 INC-104; do
        case " $got " in *" $id "*) continue ;; esac
        echo "not yet: $id is not in excluded=, and no deployment caused it."
        case $id in
          INC-102)
            echo "         Read its resolution: a power loss in the colo, and nothing rolled back. The deploy"
            echo "         on-call suspected had been running for eleven hours. Failed Deployment Recovery Time"
            echo "         counts failures a change caused; a datacentre outage belongs to reliability." ;;
          INC-104)
            echo "         The payment provider's own incident, recovered on their side with nothing deployed."
            echo "         It hurt customers and it is not a failed deployment." ;;
        esac
        exit 1
      done
      for id in $got; do
        case " $change_caused " in
          *" $id "*)
            echo "not yet: $id is in excluded=, and its resolution is a revert or a fix that was deployed."
            echo "         A deployment caused it; it counts."
            exit 1 ;;
        esac
      done

      deploys=$(measure deploys | grep -c . || true)
      if [ "$deploys" -lt 10 ]; then
        echo "not yet: could not read checkout's deploy history from the forge — reset the lesson."
        exit 1
      fi
      want_cfr=$(awk -v f=4 -v d="$deploys" 'BEGIN { printf "%.1f", 100 * f / d }')
      cfr=$(num change-failure-rate)
      # A fraction is the same answer written differently.
      if [ -n "$cfr" ] && awk -v c="$cfr" 'BEGIN { exit !(c > 0 && c < 1) }'; then
        cfr=$(awk -v c="$cfr" 'BEGIN { printf "%.2f", c * 100 }')
      fi
      if [ -z "$cfr" ] || ! awk -v g="$cfr" -v w="$want_cfr" 'BEGIN { d = g - w; exit !(d < 0.5 && d > -0.5) }'; then
        echo "not yet: change-failure-rate=$(val change-failure-rate), and it is 4 failed deployments out of $deploys: $want_cfr%."
        if [ -n "$cfr" ] && awk -v g="$cfr" -v w="$(awk -v d="$deploys" 'BEGIN { print 100 * 6 / d }')" 'BEGIN { d = g - w; exit !(d < 0.5 && d > -0.5) }'; then
          echo "         That is all six incidents over the deploys — the two you excluded are still in the numerator."
        elif [ -n "$cfr" ] && awk -v g="$cfr" -v w="$(awk -v d="$((deploys + 2))" 'BEGIN { print 100 * 4 / d }')" 'BEGIN { d = g - w; exit !(d < 0.5 && d > -0.5) }'; then
          echo "         The denominator has the two aborted attempts in it. They never reached production."
        else
          echo "         The denominator is production deployments that succeeded — count-your-deploys' number."
        fi
        exit 1
      fi

      recovery=$(measure recovery "$(cat "$work/incidents.csv")")
      want=$(printf '%s\n' "$recovery" | awk -v ids="$change_caused" '
        BEGIN { split(ids, a, " "); for (i in a) keep[a[i]] = 1 }
        keep[$1] { v[++n] = $2 }
        END {
          for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
          print (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
        }')
      med=$(num recovery-median-minutes)
      if [ -z "$med" ] || ! awk -v g="$med" -v w="$want" 'BEGIN { d = g - w; exit !(d <= 5 && d >= -5) }'; then
        echo "not yet: recovery-median-minutes=$(val recovery-median-minutes), and the median over the four failed"
        echo "         deployments is $want minutes."
        detect=$(awk -F, -v ids="$change_caused" '
          BEGIN { split(ids, a, " "); for (i in a) keep[a[i]] = 1 }
          keep[$1] {
            split($2, s, /[T:]/); split($3, e, /[T:]/)
            if (s[1] == e[1]) v[++n] = (e[2] - s[2]) * 60 + (e[3] - s[3])
          }
          END { if (n == 4) { for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }; print (v[2] + v[3]) / 2 } }' "$work/incidents.csv")
        if [ -n "$med" ] && [ -n "$detect" ] && awk -v g="$med" -v w="$detect" 'BEGIN { d = g - w; exit !(d <= 5 && d >= -5) }'; then
          echo "         $med is detection to resolution. The failure began when the deployment went out,"
          echo "         and customers were living with it before anyone was paged. Start at the deploy's tag date."
        else
          echo "         For each, take the suspected deploy's tag date (git for-each-ref --format='%(taggerdate:iso)')"
          echo "         and the incident's resolved_at."
        fi
        exit 1
      fi

      echo "PASS — 4 of $deploys deployments failed ($want_cfr%), recovered in a median of $want minutes. The power"
      echo "       cut and the provider's outage were real incidents, and they belong to reliability, not delivery."
---
