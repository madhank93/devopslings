---
kind: lesson
title: "checkout failed its game day, and every pattern is switched on"
description: |
  shop has a timeout, a bulkhead, retries, a circuit breaker and a fallback
  price, and it still fails the replay of last month's pricing incident. That is
  the whole ticket, every time — because one setting was drawn at random from
  five and broken: a timeout longer than the hang, a fallback that is empty,
  retries that include 404s, a breaker that never trips, a bulkhead as wide as
  the thread pool. The drill is reading the game day's counters in order.
name: resilience-triage-drill
slug: resilience-triage-drill
createdAt: "2026-10-09"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.resilience-triage-drill
      G="$1/files/gameday.sh"
      S="$DEVOPSLINGS_ROOT/scratch/resilience-triage-drill"

      # .env and scratch/ live outside any container, so `compose down -v` does
      # not reset them; a solved attempt would otherwise stay solved.
      mkdir -p "$S"
      rm -f "$S/triage.md" "$S/last-run" "$S/.state"
      printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$G" > "$S/gameday"
      chmod +x "$S/gameday"

      # ---- seed one fault -------------------------------------------------
      faults="timeout fallback retry breaker bulkhead"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      timeout=2 pool=8 fallback=39.99 retry_on=connect,5xx threshold=5
      case "$fault" in
        timeout)  timeout=30 ;;            # "generous", and longer than any hang
        fallback) fallback= ;;
        retry)    retry_on=connect,5xx,4xx ;;
        breaker)  threshold=50 ;;          # "so it stops flapping"
        bulkhead) pool=16 ;;               # as many as shop has threads
      esac
      cat > .env <<ENV
      # shop's resilience settings. The game day reads them when it starts shop
      # (scratch/resilience-triage-drill/gameday), so no restart is needed.
      #
      # seconds shop waits for pricing's answer; 0 = no limit
      PRICING_TIMEOUT=$timeout
      # most requests inside a pricing call at once (shop has 16 threads); 0 = no cap
      PRICING_POOL=$pool
      # price served when pricing cannot answer; empty = answer 503
      FALLBACK_PRICE=$fallback
      # attempts per pricing call, including the first
      RETRY_MAX_ATTEMPTS=3
      # failures that are retried: any of connect, timeout, 5xx, 4xx
      RETRY_ON=$retry_on
      # consecutive failures before the breaker opens; 0 = no breaker
      BREAKER_THRESHOLD=$threshold
      # seconds the breaker stays open before it lets one trial call through
      BREAKER_COOLDOWN_S=5
      # recommendations for /browse
      RECS_URL=http://toxiproxy:21215
      ENV

      "$G" start
      if out=$("$G" run 2>&1); then
        echo "the $fault fault was seeded and the game day still passes:"
        printf '%s\n' "$out"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # the game day passing with the settings repaired.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > "$S/.state"

      cat <<'Q'
      checkout failed its game day: the replay of last month's pricing incident.

        scratch/resilience-triage-drill/gameday      run it again (about a minute)

      shop serves /checkout (which calls pricing) and /browse (which does not)
      from 16 worker threads. Its settings are in sandboxes/chaos-stack/.env,
      and every pattern this module built is switched on. Exactly one setting
      was then broken — drawn at random from five.

      1. Make the game day pass by repairing the one setting that was broken,
         and nothing else.

      2. Write scratch/resilience-triage-drill/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the counter or number in the report that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order you read the
      counters in, not the answer.

      Q
      printf '%s\n' "$out"

  # Restarts metered pricing and shop from the current .env, so every check
  # grades the settings as written, from empty counters. A shop that will not
  # start on the student's settings does not fail this task; the check says why.
  inject_fault:
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.resilience-triage-drill
      "$1/files/gameday.sh" start
      echo "game day armed: resets, then a rush with pricing slow, then pricing hung"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.resilience-triage-drill
      G="$1/files/gameday.sh"
      S="$DEVOPSLINGS_ROOT/scratch/resilience-triage-drill"
      indent() { sed 's/^/         /'; }

      digest=$(cat "$S/.state" 2>/dev/null || true)
      fault=""
      for cand in timeout fallback retry breaker bulkhead; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: scratch/resilience-triage-drill/.state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before it"
        echo "         can be graded."
        exit 1
      fi

      KNOBS="PRICING_TIMEOUT PRICING_POOL FALLBACK_PRICE RETRY_MAX_ATTEMPTS RETRY_ON BREAKER_THRESHOLD BREAKER_COOLDOWN_S RECS_URL"
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"\r' | xargs || true; }
      # What init wrote: the healthy settings with the drawn one broken.
      seeded() {
        case "$fault:$1" in
          timeout:PRICING_TIMEOUT) echo 30 ;;
          fallback:FALLBACK_PRICE) echo "" ;;
          retry:RETRY_ON) echo connect,5xx,4xx ;;
          breaker:BREAKER_THRESHOLD) echo 50 ;;
          bulkhead:PRICING_POOL) echo 16 ;;
          *:PRICING_TIMEOUT) echo 2 ;;
          *:PRICING_POOL) echo 8 ;;
          *:FALLBACK_PRICE) echo 39.99 ;;
          *:RETRY_MAX_ATTEMPTS) echo 3 ;;
          *:RETRY_ON) echo connect,5xx ;;
          *:BREAKER_THRESHOLD) echo 5 ;;
          *:BREAKER_COOLDOWN_S) echo 5 ;;
          *:RECS_URL) echo http://toxiproxy:21215 ;;
        esac
      }
      case "$fault" in
        timeout) knob=PRICING_TIMEOUT ;; fallback) knob=FALLBACK_PRICE ;; retry) knob=RETRY_ON ;;
        breaker) knob=BREAKER_THRESHOLD ;; bulkhead) knob=PRICING_POOL ;;
      esac

      # ---- the red herring ----------------------------------------------
      if [ "$(env_val RECS_URL)" != "$(seeded RECS_URL)" ]; then
        echo "not yet: RECS_URL is '$(env_val RECS_URL)', not $(seeded RECS_URL)."
        echo "         Recommendations were decommissioned and refuse every connection,"
        echo "         instantly — browse serves bestsellers, as designed. A refusal costs"
        echo "         nothing; it was never the fault. Put it back."
        exit 1
      fi

      # ---- one setting was broken ------------------------------------------
      changed=""
      for k in $KNOBS; do
        [ "$(env_val "$k")" = "$(seeded "$k")" ] || changed="$changed $k"
      done
      set -- $changed
      if [ "$#" -ge 2 ]; then
        echo "not yet: $# settings differ from how the scenario left them:$changed."
        echo "         One setting was broken. Put back every one your evidence does"
        echo "         not implicate — retuning the rest hides which one it was."
        exit 1
      fi
      thr=$(env_val BREAKER_THRESHOLD)
      if printf '%s' "$thr" | grep -Eq '^[12]$'; then
        echo "not yet: BREAKER_THRESHOLD=$thr opens the breaker on one or two failures."
        echo "         One reset is noise; a breaker that trips on it cuts customers off a"
        echo "         healthy pricing. Open on a run of failures, not a single one."
        exit 1
      fi

      if ! docker compose exec -T checkout python3 -c \
           "import urllib.request; urllib.request.urlopen('http://localhost:8214/health', timeout=2)" \
           >/dev/null 2>&1; then
        echo "not yet: shop did not start with the settings in .env:"
        docker compose exec -T checkout tail -5 /opt/triage/shop.log 2>/dev/null | indent || true
        exit 1
      fi

      # ---- the game day ---------------------------------------------------
      rc=0
      out=$("$G" run 2>&1) || rc=$?
      kv() { awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$S/last-run" 2>/dev/null || true; }
      if [ -z "$(kv ok_steady)" ] || [ -z "$(kv steady_orders)" ]; then
        printf '%s\n' "$out" | tail -15
        echo "not yet: the game day did not finish, so there is nothing to grade — output above."
        exit 1
      fi
      tmo=$(env_val PRICING_TIMEOUT); pool=$(env_val PRICING_POOL); fb=$(env_val FALLBACK_PRICE)
      att=$(env_val RETRY_MAX_ATTEMPTS); ron=$(env_val RETRY_ON); cool=$(env_val BREAKER_COOLDOWN_S)
      has() { printf ',%s,' "$ron" | grep -q ",$1,"; }
      num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
      failed() { [ "$(kv "fail.$1")" = 1 ]; }

      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out"
        echo
        if failed retried_404; then
          echo "not yet: pricing received $(kv retried_404) requests it had already answered 404."
          echo "         A 404 is an answer: it is a 404 on every attempt, and each retry is"
          echo "         load pricing does for nothing."
          has 4xx && echo "         RETRY_ON='$ron' includes 4xx."
        elif failed 'checks{phase:steady}'; then
          echo "not yet: with nothing slow, only $(awk -v r="$(kv ok_steady)" 'BEGIN{printf "%.1f%%", r*100}') of checkouts got pricing's answer."
          echo "         5% of connections are reset before they reach pricing, and"
          if ! has connect; then
            echo "         a retry fixes each one — but RETRY_ON='$ron' does not include connect,"
            echo "         which is what a reset is."
          else
            echo "         a retry fixes each one — but RETRY_MAX_ATTEMPTS='$att' leaves too few."
          fi
        elif failed 'http_req_duration{route:browse}' || failed 'checks{route:browse}'; then
          echo "not yet: browse, which never calls pricing, had a p95 of $(kv browse_p95_ms)ms."
          echo "         Its handler only refuses a recommendations call and answers; the rest"
          echo "         of that time was spent waiting for one of shop's 16 worker threads."
          if [ "${pool:-0}" = 0 ] || num_ge "${pool:-0}" 16; then
            echo "         PRICING_POOL='$pool' lets checkout's pricing calls take every thread."
          fi
        elif failed 'http_req_duration{route:checkout}'; then
          echo "not yet: a checkout took $(awk -v m="$(kv checkout_max_ms)" 'BEGIN{printf "%.1f", m/1000}')s; the budget is 3s, worst case."
          if [ "${tmo:-0}" = 0 ]; then
            echo "         PRICING_TIMEOUT=0 waits for pricing forever, and in the outage pricing"
            echo "         takes 8s."
          elif num_ge "$tmo" 8; then
            echo "         PRICING_TIMEOUT=$tmo is longer than the 8s pricing hangs for, so it never"
            echo "         fired: the call just waited and succeeded late. A timeout bounds"
            echo "         nothing if it is longer than the wait it guards against."
          elif has timeout; then
            echo "         RETRY_ON='$ron' retries a timeout, so the worst case is"
            echo "         $att attempts x ${tmo}s, not ${tmo}s."
          elif num_ge "$tmo" 3; then
            echo "         PRICING_TIMEOUT=$tmo: a request that waits out the timeout has already"
            echo "         missed a 3s budget."
          fi
        elif failed rush_sold; then
          echo "not yet: shop sold only $(kv rush_sold) checkouts at pricing's price in the rush (needs 30)."
          echo "         pricing was slow but answering, in 1.5s a call."
          if [ "${tmo:-0}" != 0 ] && ! num_ge "$tmo" 1.5; then
            echo "         PRICING_TIMEOUT=$tmo is shorter than pricing's 1.5s, so every call was"
            echo "         abandoned. Slow is not broken; a timeout under it makes it broken."
          elif [ "${pool:-0}" != 0 ]; then
            echo "         PRICING_POOL=$pool lets only $pool calls through at a time, each held 1.5s."
          fi
        elif failed 'checks{phase:rush}' || failed 'checks{phase:outage}'; then
          echo "not yet: checkouts were answered 503 while pricing was slow and then hung."
          echo "         $(kv rush_failed_503) in the rush, $(kv outage_failed_503) in the outage."
          if [ -z "$fb" ]; then
            echo "         Refusing fast is half of it: FALLBACK_PRICE is empty, so a refused"
            echo "         or failed pricing call becomes a customer's error."
          fi
        elif failed outage_calls; then
          echo "not yet: pricing received $(kv outage_calls) calls in the 10s it was hung; the limit is 20."
          echo "         The breaker opened $(kv breaker_opens) times. Every one of those calls"
          echo "         waited out the timeout to learn what the last one already knew."
          echo "         BREAKER_THRESHOLD=$(env_val BREAKER_THRESHOLD)."
        elif failed 'checks{phase:after}'; then
          echo "not yet: pricing had been healthy for 8s and checkouts still did not get its price."
          echo "         BREAKER_COOLDOWN_S=$cool — an open breaker has to let a"
          echo "         trial through, and close when it succeeds."
        else
          echo "not yet: the game day failed a threshold not covered above — output above."
        fi
        exit 1
      fi

      if [ "$(env_val "$knob")" = "$(seeded "$knob")" ]; then
        echo "not yet: the game day passes, but the setting that was broken is still as"
        echo "         the scenario left it. What you changed ($changed ) hid it."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      T="$S/triage.md"
      if [ ! -s "$T" ]; then
        echo "not yet: scratch/resilience-triage-drill/triage.md is missing or empty."
        echo "         Three lines: cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$T")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      re_timeout='\b(timeouts?|timed? ?out|pricing_timeout|hang\w*|hung|wait(s|ed|ing)? (forever|indefinitely))\b'
      re_fallback='\b(fallback\w*|fall ?back|fallback_price|503s?|default price)\b'
      re_retry='\b(4xx|404s?|not found|client errors?)\b'
      re_breaker='\b(breaker\w*|circuit|breaker_threshold)\b'
      re_bulkhead='\b(bulkheads?|pricing_pool|pools?|threads?|starv\w*|exhaust\w*)\b'
      case "$fault" in
        timeout)
          what="PRICING_TIMEOUT was 30s, longer than the 8s pricing hung for, so it never fired: checkouts waited 8s and the breaker never saw a failure"
          c_re=$re_timeout
          e_re='\b(slowest|max\w*|p99|latency|duration|8(\.[0-9]+)? ?s|8000 ?ms|timeouts?|0 times)\b'
          e_say="the outage row's slowest checkout at about 8s, with 0 timeouts and the breaker opened 0 times"
          d_re='\b(latency|p9[0-9]|max\w*|duration|slow\w*|timeouts?|seconds?|budget)\b'
          d_say="checkout latency at p99 or max, against the budget" ;;
        fallback)
          what="FALLBACK_PRICE was empty, so every call refused by the bulkhead or the open breaker became a 503 instead of a price"
          c_re=$re_fallback
          e_re='\b(503s?|failed_503|errors?|status|pool full|breaker open|refused)\b'
          e_say="the 503 column in the rush and outage rows, matching pool refused and breaker refused"
          d_re='\b(5xx|503s?|error rate|errors?|fallback\w*|availability|success rate)\b'
          d_say="checkout's 5xx rate" ;;
        retry)
          what="RETRY_ON included 4xx, so every 404 for a retired SKU was asked again until the attempts ran out"
          c_re=$re_retry
          e_re='\b(404s?|again|repeated|received|amplif\w*|per (order|checkout)|calls?)\b'
          e_say="pricing's own counter of requests that arrived again after it answered 404, or pricing receiving more than shop had orders"
          d_re='\b(4xx|404s?|retr\w*|requests? per|amplif\w*|repeat\w*|ratio|duplicate\w*)\b'
          d_say="pricing requests per checkout, or retries of 4xx responses" ;;
        breaker)
          what="BREAKER_THRESHOLD was 50, more consecutive failures than the outage produced, so the breaker never opened and every call waited out the timeout"
          c_re=$re_breaker
          e_re='\b(opened|outage|calls|received|timeouts?|0 times)\b'
          e_say="pricing receiving about 40 calls while hung, shop's timeouts climbing, and the breaker opened 0 times"
          d_re='\b(breakers?|calls?|request rate|requests|error rate|state|open\w*|timeouts?)\b'
          d_say="calls to a dependency while its error rate is high, or a breaker that stays closed through them" ;;
        bulkhead)
          what="PRICING_POOL was 16, as many as shop's worker threads, so the rush put every thread inside a slow pricing call and browse queued for one"
          c_re=$re_bulkhead
          e_re='\b(browse|p95|handler|threads?|queue\w*|pool refused|refused|latency)\b'
          e_say="browse's p95 in seconds while its handler took milliseconds, and pool refused at 0 in the rush"
          d_re='\b(browse|p9[0-9]|latency|threads?|pools?|saturat\w*|utili[sz]\w*|queue\w*|busy)\b'
          d_say="latency of the route that does not call pricing, or worker threads busy" ;;
      esac

      named=0
      for re in "$re_timeout" "$re_fallback" "$re_retry" "$re_breaker" "$re_bulkhead"; do
        if printf '%s' "$a_cause" | grep -Eq "$re"; then named=$((named + 1)); fi
      done
      if [ "$named" -ge 3 ]; then
        echo "not yet: cause names $named different faults. One was seeded; say which,"
        echo "         and what about it failed the game day."
        exit 1
      fi
      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and the game day passes, so"
        echo "         something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before the game day did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 1% for 5 minutes', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired in the one setting that broke:"
      echo "       resets retried, browse untouched by the rush, nobody past the budget,"
      echo "       a price for every customer, pricing left alone while it was down,"
      echo "       and recommendations still refusing, as they have for months."
---
