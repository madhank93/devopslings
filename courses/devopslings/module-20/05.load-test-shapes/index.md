---
kind: lesson
title: "Five tests, one service"
description: |
  The shipping-quote service passes its load test every release, and falls
  over in production every afternoon. The load test is a ramp. Write the
  other four shapes, ramp, soak, spike, stress and breakpoint, run all five,
  and name the failure only one of them finds.
name: load-test-shapes
slug: load-test-shapes
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.load-test-shapes
      lesson=$1
      mkdir -p answers
      rm -f answers/{ramp,soak,spike,stress,breakpoint}.{js,json} answers/shapes.txt
      cp "$lesson/files/ramp.js" answers/ramp.js
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true
      # Summaries older than this are from an earlier attempt.
      touch answers/.load-shapes-started

      echo "scenario ready — quote is on checkout:8250; its memory and restarts: curl via"
      echo "  docker compose exec -T checkout python3 -c \"import urllib.request as u; print(u.urlopen('http://localhost:8250/stats').read().decode())\""
      echo
      echo "The release test is answers/ramp.js. Write soak.js, spike.js, stress.js and breakpoint.js"
      echo "beside it, and run each with:  bash $lesson/files/run.sh <shape>"

  verify_done:
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.load-test-shapes
      lesson=$1
      profile() {
        docker compose exec -T k6 sh -c 'cat > /tmp/inspect.js && k6 inspect /tmp/inspect.js' < "answers/$1.js" 2>/dev/null \
          | jq -c -f "$lesson/files/profile.jq" 2>/dev/null || true
      }
      get() { jq -r ".$1" <<<"$p"; }
      for shape in ramp soak spike stress breakpoint; do
        if [ ! -s "answers/$shape.js" ]; then
          echo "not yet: answers/$shape.js does not exist. Each of the five shapes is its own script."
          exit 1
        fi
        p=$(profile "$shape")
        if [ -z "$p" ]; then
          echo "not yet: k6 cannot read answers/$shape.js. Run it with run.sh and read k6's error."
          exit 1
        fi
        case "$(get exec)" in
          constant-arrival-rate|ramping-arrival-rate) ;;
          *) echo "not yet: answers/$shape.js does not use an arrival-rate executor in its first scenario."
             echo "The shapes are about requests a second, which only an open model controls (lesson 04)."
             exit 1 ;;
        esac
        total=$(get total); peak=$(get peak)
        case $shape in
          soak)
            if awk -v t="$total" -v p="$peak" 'BEGIN { exit !(t < 75 || p > 150 || p < 50) }'; then
              echo "not yet: answers/soak.js runs ${total}s at up to $peak a second. A soak holds normal"
              echo "load, 50 to 150 a second here, for far longer than any other test: at least 75s"
              echo "on this lab's compressed clock."
              exit 1
            fi ;;
          spike)
            if [ "$(get spike)" != true ] || awk -v t="$total" 'BEGIN { exit !(t > 40) }'; then
              echo "not yet: answers/spike.js has no spike. A spike jumps from normal load to 400 a second or"
              echo "more, at least fourfold, within 5 seconds, and the whole test fits in 40s."
              exit 1
            fi ;;
          stress)
            if awk -v h="$(get held200)" -v t="$total" 'BEGIN { exit !(h < 15 || t > 40) }'; then
              echo "not yet: answers/stress.js holds 200 a second or more for $(get held200)s. A stress test sits"
              echo "well above normal load, twice it or more, for at least 15s, within 40s in all."
              exit 1
            fi ;;
          breakpoint)
            if [ "$(get exec)" != ramping-arrival-rate ] || [ "$(get abort)" != true ] || \
               awk -v p="$peak" -v t="$total" 'BEGIN { exit !(p < 600 || t > 60) }'; then
              echo "not yet: answers/breakpoint.js must keep raising the rate, to 600 a second or more within"
              echo "60s, and stop itself the moment the service breaks: a threshold with abortOnFail: true."
              exit 1
            fi ;;
          *)
            if awk -v t="$total" 'BEGIN { exit !(t > 40) }'; then
              echo "not yet: answers/ramp.js runs ${total}s; keep it within 40s."
              exit 1
            fi ;;
        esac
        if [ ! answers/$shape.json -nt answers/.load-shapes-started ]; then
          echo "not yet: answers/$shape.json is missing or older than the lesson's start: run the test"
          echo "with bash $lesson/files/run.sh $shape."
          exit 1
        fi
      done
      soak_failed=$(jq -r '.metrics.http_req_failed.value // 0' answers/soak.json 2>/dev/null || echo 0)
      restarts=$(docker compose exec -T checkout python3 -c "import urllib.request as u; print(u.urlopen('http://localhost:8250/stats', timeout=5).read().decode())" 2>/dev/null | jq -r '.restarts // 0' 2>/dev/null || echo 0)
      if awk -v f="$soak_failed" 'BEGIN { exit !(f == 0) }' || [ "$restarts" = 0 ]; then
        echo "not yet: the soak run in answers/soak.json had no failures. Rerun it as it is now:"
        echo "bash $lesson/files/run.sh soak, and watch quote's /stats while it runs."
        exit 1
      fi
      ans=answers/shapes.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
      only=$(field only_one | tr -d ' \r' | tr '[:upper:]' '[:lower:]')
      failure=$(field failure)
      bp=$(field breakpoint_rps | tr -dc '0-9.')
      if [ -z "$only" ] || [ -z "$failure" ] || [ -z "$bp" ]; then
        echo "not yet: $ans needs only_one=<shape>, failure=<what broke> and breakpoint_rps=<n>."
        exit 1
      fi
      case "$only" in
        soak) ;;
        spike) echo "not yet: only_one=spike. The spike's 503s are the queue overflowing, and the breakpoint"
               echo "test hits the same 503s once it passes capacity. Which failure did no other test show?"
               exit 1 ;;
        breakpoint|stress) echo "not yet: only_one=$only. Running past capacity gives 503s whichever test gets"
               echo "there, the spike shows them too. Which failure did no other test show?"
               exit 1 ;;
        ramp) echo "not yet: only_one=ramp. The ramp is the test that passes every release."
              exit 1 ;;
        *) echo "not yet: only_one=$only. Name one of ramp, soak, spike, stress, breakpoint."
           exit 1 ;;
      esac
      if ! grep -Eqi '\b(memory|leak(s|ed|ing)?|oom|rss|restart(s|ed)?|killed)\b' <<<"$failure"; then
        echo "not yet: failure= has to say what broke during the soak. Watch quote's /stats while"
        echo "the soak runs, and read the end of its log:"
        echo "docker compose exec -T checkout tail /srv/load-shapes/quote.log"
        exit 1
      fi
      # quote's capacity is 320/s; k6 evaluates abortOnFail every couple of seconds, so a steep ramp overshoots it.
      if awk -v b="$bp" 'BEGIN { exit !(b < 240 || b > 460) }'; then
        echo "not yet: breakpoint_rps=$bp. That is not where quote starts to fail. The breakpoint test"
        echo "aborts when failures cross its threshold: work out the arrival rate its ramp had reached"
        echo "at that moment, from how long it ran (http_reqs count over rate) and how its stages raise"
        echo "the rate."
        exit 1
      fi
      echo "PASS — five shapes run; only the soak found quote being killed for memory; it breaks near $bp a second."
---
