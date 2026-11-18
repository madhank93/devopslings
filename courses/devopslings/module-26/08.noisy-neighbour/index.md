---
kind: lesson
title: "One team's backfill, everyone's queue"
description: |
  When the data team backfills, it queues a hundred and sixty builds at once
  on the shared runner pool, and for the next minute nobody else's build
  starts. The request on the platform's board is "more runners". Keep every
  other team's builds moving through the next burst, let the data team's
  backfill still finish, and say why your mechanism beats the two you
  rejected.
name: noisy-neighbour
slug: noisy-neighbour
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      obs-reset >/dev/null
      rm -rf /obs/platform
      mkdir -p /obs/platform

      # The model. The grader refuses to run against an edited copy.
      cat > /obs/apps/gateway_exporter.py <<'PY'
      """platform-sim: a shared CI runner pool and its scheduler, on :9101.

      A model of scheduling, not of CI. Four tenants submit builds at a steady
      rate; every build takes two seconds on a runner. The scheduler reads
      /obs/platform/runners.yml every tick. When /obs/run/sim-burst appears,
      the data tenant submits 160 builds at once, and the file is removed.
      """
      import collections
      import os
      import random
      import time

      import yaml
      from prometheus_client import Counter, Gauge, start_http_server

      TENANTS = ["web", "api", "payments", "data"]
      RATE = 0.6        # builds per second per tenant
      JOB = 2.0         # seconds per build
      TICK = 0.05

      submitted = Counter("runner_jobs_submitted", "Builds submitted.", ["tenant"])
      completed = Counter("runner_jobs_completed", "Builds finished.", ["tenant"])
      waited = Counter("runner_job_wait_seconds", "Seconds builds waited in the queue before starting.", ["tenant"])
      queued = Gauge("runner_queue_depth", "Builds waiting.", ["tenant"])
      running = Gauge("runner_jobs_running", "Builds on a runner now.", ["tenant"])
      capacity = Gauge("runner_pool_size", "Runners in the pool.")


      def config():
          try:
              c = yaml.safe_load(open("/obs/platform/runners.yml")) or {}
          except Exception:
              c = {}
          return c if isinstance(c, dict) else {}


      queue = collections.deque()          # (tenant, submitted_at), in arrival order
      busy = []                            # (tenant, ends_at, pool)
      last = time.time()
      start_http_server(9101)
      for t in TENANTS:
          submitted.labels(t); completed.labels(t); waited.labels(t)

      while True:
          now = time.time()
          c = config()
          runners = int(c.get("runners", 8) or 8)
          scheduler = c.get("scheduler", "fifo")
          shares = c.get("shares") or {}
          caps = c.get("max_concurrent") or {}
          pools = c.get("pools") or {}
          capacity.set(runners)

          if os.path.exists("/obs/run/sim-burst"):
              os.remove("/obs/run/sim-burst")
              for _ in range(160):
                  queue.append(("data", now)); submitted.labels("data").inc()
          # Arrivals follow the clock, not the tick count, so a slow tick does not thin them.
          dt, last = now - last, now
          for t in TENANTS:
              if random.random() < RATE * dt:
                  queue.append((t, now)); submitted.labels(t).inc()

          for job in [j for j in busy if j[1] <= now]:
              busy.remove(job); completed.labels(job[0]).inc()

          # Which pool a tenant's builds run in, and each pool's size.
          pool_of = {t: "shared" for t in TENANTS}
          sizes = {"shared": runners}
          if pools:
              sizes = {}
              for name, p in pools.items():
                  sizes[name] = int((p or {}).get("runners", 0))
                  for t in (p or {}).get("tenants", []) or []:
                      pool_of[t] = name
              if sum(sizes.values()) > runners:
                  sizes = {"shared": runners}
                  pool_of = {t: "shared" for t in TENANTS}

          def can_start(t):
              p = pool_of.get(t, "shared")
              in_pool = sum(1 for j in busy if j[2] == p)
              mine = sum(1 for j in busy if j[0] == t)
              return in_pool < sizes.get(p, 0) and (t not in caps or mine < int(caps[t]))

          def start(i):
              t, at = queue[i]
              del queue[i]
              waited.labels(t).inc(now - at)
              busy.append((t, now + JOB, pool_of.get(t, "shared")))

          progress = True
          while progress and queue:
              progress = False
              if scheduler == "fair":
                  # Weighted round robin: the waiting tenant with the least running per share goes next.
                  waiting = [t for t in TENANTS if any(q[0] == t for q in queue) and can_start(t)]
                  if waiting:
                      t = min(waiting, key=lambda t: (sum(1 for j in busy if j[0] == t) / float(shares.get(t, 1) or 1), random.random()))
                      start(next(i for i, q in enumerate(queue) if q[0] == t))
                      progress = True
              else:
                  for i, (t, _) in enumerate(queue):
                      if can_start(t):
                          start(i); progress = True
                          break
                      if not caps and not pools:
                          break  # fifo: the head of the line blocks everyone behind it

          for t in TENANTS:
              queued.labels(t).set(sum(1 for q in queue if q[0] == t))
              running.labels(t).set(sum(1 for j in busy if j[0] == t))
          time.sleep(TICK)
      PY

      cat > /obs/platform/runners.yml <<'YML'
      # The shared CI runner pool. Budget: 8 runners.
      runners: 8

      # One queue, first come, first served.
      scheduler: fifo

      # What else the scheduler supports:
      #
      #   scheduler: fair            the waiting tenant with the fewest running builds
      #                              (per unit of share) starts next
      #   shares: {web: 1, ...}      weights for fair; default 1
      #
      #   max_concurrent: {data: 4}  at most this many of a tenant's builds run at once;
      #                              the rest wait, and others' builds go past them
      #
      #   pools:                     dedicated runners; the sizes add up to at most runners
      #     batch: {runners: 3, tenants: [data]}
      #     shared: {runners: 5, tenants: [web, api, payments]}
      YML

      cat > /obs/platform/BOARD.md <<'MD'
      # Platform board

      - **More runners.** "Builds sat for a minute again during the data backfill."
        — web, api, payments (14 votes)
      - **Kill the data team's backfills during the day.** — api (6 votes)
      - **Our backfill has to finish within its window.** — data (1 vote)
      MD

      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: platform
          static_configs:
            - targets: ["gateway-exporter:9101"]
      YML
      chmod -R a+rwX /obs/platform
      chmod -R a+rX /obs/prometheus /obs/apps
      obs-reload >/dev/null
      . /usr/local/lib/obs.sh
      prom_wait 'runner_jobs_completed_total{job="platform"}' 60 || { echo "the simulator never came up; see /obs/logs/gateway-exporter.log"; exit 1; }
      echo "scenario ready: the pool's config is /obs/platform/runners.yml. Start a backfill with"
      echo "  touch /obs/run/sim-burst"
      echo "and watch:  promq 'sum by (tenant) (rate(runner_jobs_completed_total[20s]))'"
      echo "Write your decision to /obs/answers/noisy-neighbour.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 400
    run: |
      . /usr/local/lib/obs.sh
      a=/obs/answers/noisy-neighbour.txt
      cfg=/obs/platform/runners.yml

      if [ "$(sha256sum /obs/apps/gateway_exporter.py 2>/dev/null | cut -c1-64)" != "f50bbe17140ab6c58d724c34e6085a08f9ceb5fe7f8656e856ba5ab35dba1a84" ]; then
        echo "not yet: /obs/apps/gateway_exporter.py is not the simulator this lesson started. It is the"
        echo "         model the check measures against; reset the lesson to get it back."
        exit 1
      fi
      cfgval() { python3 -c 'import sys, yaml
      c = yaml.safe_load(open(sys.argv[1])) or {}
      v = c.get(sys.argv[2]) if isinstance(c, dict) else None
      print("" if v is None else v)' "$cfg" "$1" 2>/dev/null || echo error; }

      runners=$(cfgval runners)
      if [ "$runners" != 8 ]; then
        echo "not yet: runners is ${runners:-unset}; the budget is 8. More runners make the queue drain"
        echo "         sooner, and the next backfill is bigger: the other teams still wait behind it."
        exit 1
      fi
      sched=$(cfgval scheduler); caps=$(cfgval max_concurrent); pools=$(cfgval pools)
      if [ -n "$pools" ]; then mech=pools
      elif [ "$sched" = fair ]; then mech=fair
      elif [ -n "$caps" ]; then mech=cap
      else mech=none
      fi

      # Counters straight from the simulator, so a burst is measured to the second.
      snap() { curl -s --max-time 5 http://gateway-exporter:9101/metrics | awk '/^runner_jobs_(completed|submitted)_total\{/ { k = ($0 ~ /^runner_jobs_completed/) ? "done" : "sub"; match($0, /tenant="[^"]*"/); t = substr($0, RSTART + 8, RLENGTH - 9); printf "%s_%s=%d ", k, t, $2 }'; }
      depth() { curl -s --max-time 5 http://gateway-exporter:9101/metrics | awk -v t="$1" '$0 ~ "^runner_queue_depth\\{tenant=\"" t "\"" { printf "%d", $2 }'; }
      count() { sed -n "s/.*[ ]$2=\([0-9]*\).*/\1/p" <<<" $1"; }

      # Start from a drained queue.
      for _ in $(seq 1 120); do
        [ "$(depth data)" = 0 ] && break
        sleep 1
      done
      if [ "$(depth data)" != 0 ]; then
        echo "not yet: the data team's queue has not drained in two minutes before the burst even starts."
        exit 1
      fi

      touch /obs/run/sim-burst
      sleep 4
      s0=$(snap); sleep 25; s1=$(snap)
      for t in web api payments; do
        n=$(( $(count "$s1" done_$t) - $(count "$s0" done_$t) ))
        sub=$(( $(count "$s1" sub_$t) - $(count "$s0" sub_$t) ))
        # A build takes 2 seconds, so the last few submitted may still be running.
        if [ "$n" -lt $(( sub - 4 )) ]; then
          echo "not yet: during the data team's burst, ${t} submitted ${sub} builds in 25 seconds and finished ${n}."
          echo "         Its builds are waiting behind the backfill."
          [ "$mech" = none ] && echo "         One queue, first come first served: 160 builds arrive at once, and everyone is behind them."
          exit 1
        fi
      done
      d=$(( $(count "$s1" done_data) - $(count "$s0" done_data) ))
      for _ in $(seq 1 120); do
        [ "$(depth data)" = 0 ] && break
        sleep 1
      done
      left=$(depth data)
      if [ "${left:-1}" != 0 ]; then
        echo "not yet: the other teams kept moving, and two minutes into the burst the data team still has"
        echo "         ${left} builds queued (${d} finished in the first 25 seconds). Isolation that starves the"
        echo "         heavy tenant has moved the outage, not removed it: the backfill has a window too."
        exit 1
      fi

      # The decision.
      if [ ! -s "$a" ]; then
        echo "not yet: $a is missing: a 'chosen:' line and two 'rejected:' lines, each with a reason."
        exit 1
      fi
      kind() {  # the mechanism a phrase names
        local s; s=$(tr '[:upper:]' '[:lower:]' <<<"$1")
        if grep -Eq '\b(fair|fairness|weighted|round[ -]?robin|share|shares)\b' <<<"$s"; then echo fair
        elif grep -Eq '\b(dedicated|partition|partitioned|pools?|separate runners)\b' <<<"$s"; then echo pools
        elif grep -Eq '\b(rate[ -]?limit\w*|throttl\w*|reject\w*|ban|block)\b' <<<"$s"; then echo ratelimit
        elif grep -Eq '\b(cap|caps|capped|max_concurrent|concurrency|quota|limit|limits)\b' <<<"$s"; then echo cap
        elif grep -Eq '\b(more|add|adding|scale|autoscal\w*)\b.*\brunners?\b|\brunners?\b.*\b(more|add)\b' <<<"$s"; then echo more
        elif grep -Eq '\b(priority|priorities|preempt\w*)\b' <<<"$s"; then echo priority
        else echo unknown
        fi
      }
      chosen=$(sed -n 's/^[[:space:]]*chosen[[:space:]]*:[[:space:]]*//p' "$a" | head -1)
      ck=$(kind "${chosen%%|*}")
      if [ "$ck" != "$mech" ]; then
        echo "not yet: chosen: '${chosen%%|*}' reads as ${ck}, and runners.yml runs ${mech}. Name the mechanism"
        echo "         the pool is configured with."
        exit 1
      fi
      seen=" $ck "
      n=0
      while IFS= read -r line; do
        what=${line%%|*}; why=${line#*|}
        [ "$why" = "$line" ] && why=""
        k=$(kind "$what")
        if [ "$k" = unknown ]; then
          echo "not yet: rejected: '${what}' is not a mechanism this check recognises (fair share, a"
          echo "         concurrency cap, dedicated pools, more runners, priority, rate limiting)."
          exit 1
        fi
        case "$seen" in *" $k "*)
          echo "not yet: rejected: '${what}' is the same mechanism as one already named. Reject two different ones."
          exit 1 ;;
        esac
        if [ "$(wc -w <<<"$why")" -lt 6 ]; then
          echo "not yet: rejected: '${what}' needs a reason after a '|': what it would cost, in this pool."
          exit 1
        fi
        seen="$seen$k "; n=$((n + 1))
      done < <(sed -n 's/^[[:space:]]*rejected[[:space:]]*:[[:space:]]*//p' "$a")
      if [ "$n" -lt 2 ]; then
        echo "not yet: $a rejects ${n} mechanism(s); name the two you weighed against ${ck}, each with a reason."
        exit 1
      fi

      echo "PASS — ${mech}: the other teams finished their builds through a 160-build burst, the backfill drained, and two alternatives rejected with reasons."
