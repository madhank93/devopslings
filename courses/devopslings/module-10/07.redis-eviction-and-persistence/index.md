---
kind: lesson
title: "the queue lost jobs overnight and nobody deleted anything"
description: |
  Redis was given a memory ceiling after it was OOM-killed, and the kills
  stopped. Since then the nightly cache warm takes the job queue with it, and a
  restart takes whatever is left. One Redis is holding two things with opposite
  requirements — a cache that can be thrown away and a queue that is the only
  copy of the work — and it is configured as though it held only the first.
name: redis-eviction-and-persistence
slug: redis-eviction-and-persistence
createdAt: "2026-09-23"

sandbox:
  stack: db-stack
  service: redis

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      install -d /work/app /work/answers
      rm -f /work/answers/redis-eviction.md

      # Back to the evening the incident started from, whatever the last run
      # left behind on the volume.
      redis-cli CONFIG SET appendonly no >/dev/null
      redis-cli CONFIG SET save "" >/dev/null
      redis-cli FLUSHALL >/dev/null
      rm -rf /data/appendonlydir /data/dump.rdb
      # The ceiling somebody put on after the OOM kill, and the policy they
      # picked because it was the one that made the errors stop.
      redis-cli CONFIG SET maxmemory 32mb >/dev/null
      redis-cli CONFIG SET maxmemory-policy allkeys-lru >/dev/null
      redis-cli CONFIG REWRITE >/dev/null

      cat > /work/app/enqueue.sh <<'SH'
      #!/usr/bin/env bash
      # Outbound email jobs. queue:jobs holds the ids in the order they were
      # accepted; job:<id> holds the work. Nothing else has that written down —
      # the customer was told the email was sent the moment this returned.
      set -euo pipefail
      n=${1:-200}
      batch="$(date +%s)"
      {
        for i in $(seq 1 "$n"); do
          echo "RPUSH queue:jobs $batch-$i"
          echo "HSET job:$batch-$i status queued kind email attempt 0"
        done
      } | redis-cli --pipe >/dev/null
      echo "enqueued $n jobs — queue:jobs is $(redis-cli LLEN queue:jobs) deep"
      SH
      chmod +x /work/app/enqueue.sh

      cat > /work/app/cache-warm.sh <<'SH'
      #!/usr/bin/env bash
      # Nightly cache warm: render the top product pages into Redis so the
      # morning is not spent rebuilding them out of Postgres.
      set -euo pipefail
      pages=${1:-3000}
      body="$(head -c 16384 /dev/zero | tr '\0' x)"
      {
        for i in $(seq 1 "$pages"); do
          echo "SET cache:page:$i $body"
        done
      } | redis-cli --pipe >/dev/null
      echo "warmed $pages pages — $(redis-cli DBSIZE) keys, $(redis-cli INFO memory | tr -d '\r' | sed -n 's/^used_memory_human://p') used"
      SH
      chmod +x /work/app/cache-warm.sh

      # Last night, in order: the queue filled up, and then the cache warm ran.
      bash /work/app/enqueue.sh 200 >/dev/null
      queued=$(redis-cli LLEN queue:jobs)
      bash /work/app/cache-warm.sh >/dev/null
      left=$(redis-cli LLEN queue:jobs)
      jobs=$(redis-cli --scan --pattern 'job:*' | wc -l)

      cat > /work/answers/redis-eviction.md <<'MD'
      # The queue that lost jobs overnight

      # The maxmemory-policy Redis was running under while the jobs were going
      # missing — the name redis-cli gives it.
      evicting-policy: ?

      # Under the policy that should be running instead, what has to be true of
      # a key before Redis is allowed to evict it?
      what-makes-a-key-evictable: ?

      # maxmemory was raised once already and the losses came back. The cache
      # grows for as long as there are pages to render. One line: why is a
      # bigger ceiling not the fix?
      why-not-more-memory: ?
      MD

      echo "scenario ready"
      echo
      echo "  last night: $queued jobs queued, then the cache warm ran."
      echo "  this morning: queue:jobs is $left deep and $jobs job hashes remain."
      echo
      echo "  the queue:    /work/app/enqueue.sh [count]"
      echo "  the warm:     /work/app/cache-warm.sh [pages]"
      echo "  your answer:  /work/answers/redis-eviction.md"
      echo
      echo "  redis-cli is on the PATH here and talks to this Redis."

  # A restart has to be a real restart, and Redis cannot restart itself from
  # inside the check that is measuring it. This runs on the host, before every
  # grading run.
  inject_fault:
    service: host
    timeout_seconds: 300
    run: |
      # Last night's pages first. A Redis left pinned against its ceiling with
      # nothing it is allowed to evict would refuse the grader's own writes, and
      # that is the student's answer being wrong, not the harness breaking. The
      # cache is the part that can always be thrown away.
      docker compose exec -T redis bash -c \
        "redis-cli --scan --pattern 'cache:*' | xargs -r redis-cli UNLINK" >/dev/null

      probes() {
        for i in $(seq 1 25); do
          echo "RPUSH queue:jobs GRADE-$i"
          echo "HSET job:GRADE-$i status queued kind grader attempt 0"
        done
      }
      probes | docker compose exec -T redis redis-cli --pipe >/dev/null

      # Long enough that a once-a-second AOF flush is not a coin toss.
      sleep 2
      docker compose restart redis >/dev/null

      ready=no
      for _ in $(seq 1 60); do
        if docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
          ready=yes
          break
        fi
        sleep 1
      done
      [ "$ready" = yes ] || { echo "redis did not come back after the restart"; exit 1; }
      echo "25 jobs queued, redis restarted"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      ans=/work/answers/redis-eviction.md
      app=/work/app/cache-warm.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$app" ]; then
        echo "not yet: $app is missing or empty. The cache warm still has to run."
        echo "Run 'devopslings reset redis-eviction-and-persistence' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }
      cfg() { redis-cli CONFIG GET "$1" 2>/dev/null | tail -1 | tr -d '\r' || true; }
      stat() { redis-cli INFO "$1" 2>/dev/null | tr -d '\r' | sed -n "s/^$2://p" || true; }
      probes_alive() {
        redis-cli EXISTS $(for i in $(seq 1 25); do printf 'job:GRADE-%s ' "$i"; done) 2>/dev/null || echo 0
      }

      # --- is the ceiling still a ceiling -------------------------------------
      mm=$(cfg maxmemory)
      if [ "${mm:-0}" = "0" ] || [ "${mm:-0}" -gt 67108864 ]; then
        echo "not yet: maxmemory is ${mm:-0} bytes. This box has 64MB to give Redis, and the"
        echo "page cache grows for as long as there are pages to render, so the ceiling gets"
        echo "reached either way. What is actually in question is which keys Redis is allowed"
        echo "to drop when it gets there."
        exit 1
      fi

      # --- and does the policy still consider the queue fair game -------------
      pol=$(cfg maxmemory-policy)
      case "$pol" in
        allkeys-*)
          echo "not yet: maxmemory-policy is still $pol. Read the first half of the name: at"
          echo "the ceiling Redis picks its victim from every key it holds. It has no way to"
          echo "know that job:… is the only copy of a job while cache:page:… is a copy of"
          echo "something Postgres can rebuild in a second. The other family of policies"
          echo "narrows what may be chosen — 'redis-cli CONFIG SET maxmemory-policy' with an"
          echo "invalid value will list them all."
          exit 1
          ;;
      esac

      # --- did anything survive the restart at all ----------------------------
      alive=$(probes_alive)
      if [ "${alive:-0}" != "25" ]; then
        echo "not yet: the grader queued 25 jobs, restarted Redis, and ${alive:-0} of the 25"
        echo "came back. Nothing was evicted for them to be lost to — the ceiling was never"
        echo "the problem here, the process was."
        echo
        echo "The server that came back has appendonly=$(cfg appendonly) and save='$(cfg save)'."
        echo "That is what it read from /data/redis.conf at startup, which is not necessarily"
        echo "what you set on the running server: a CONFIG SET lives exactly as long as the"
        echo "process does, and there is a command that writes the running config back to the"
        echo "file. A cache can afford to come back cold. The queue is the only copy of the"
        echo "work it is holding."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      got_pol=$(field evicting-policy | tr 'A-Z' 'a-z')
      case "$got_pol" in
        *allkeys*) ;;
        *)
          echo "not yet: 'evicting-policy:' says '${got_pol:-nothing}'. The question is which"
          echo "policy was running while the jobs were going missing, not the one you have set"
          echo "now. Its name says which keys it was choosing from, and that is the whole"
          echo "reason the queue was ever in the draw."
          exit 1
          ;;
      esac

      evictable=$(field what-makes-a-key-evictable | tr 'A-Z' 'a-z')
      if ! printf '%s' "$evictable" | grep -Eq '\b(ttl|ttls|expire|expires|expiry|expiration|expiring|volatile)\b'; then
        echo "not yet: 'what-makes-a-key-evictable:' does not name it. A volatile-* policy"
        echo "will only take keys carrying one particular thing; a key without it is never a"
        echo "candidate, which is exactly what keeps the queue out of the draw. Run"
        echo "'redis-cli TTL' against a cache key and against a job key — the difference"
        echo "between the two answers is the thing."
        exit 1
      fi

      why=$(field why-not-more-memory | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(grow|grows|growing|unbounded|eventually|postpone|postpones|postponed|delay|delays|delayed|buys|later|again|refill|refills|fill|fills|always|keeps)\b'; then
        echo "not yet: 'why-not-more-memory:' does not say what a bigger ceiling actually"
        echo "changes. It is not that the ceiling is wrong — it is that a cache with no TTLs"
        echo "will reach any ceiling you give it. Say what raising it bought, and for how"
        echo "long."
        exit 1
      fi

      # --- and now the behaviour ----------------------------------------------
      # The cache is cleared first. That is a liberty the grader can take with a
      # cache and not with a queue, which is the distinction the whole lesson is
      # about: last night's pages are rebuildable and this run needs a known
      # starting point.
      redis-cli --scan --pattern 'cache:*' 2>/dev/null | xargs -r redis-cli UNLINK >/dev/null 2>&1 || true
      redis-cli CONFIG RESETSTAT >/dev/null

      llen_before=$(redis-cli LLEN queue:jobs)
      rc=0
      timeout 300 bash "$app" >/tmp/grader-cache-warm.log 2>&1 || rc=$?

      oom=$(stat errorstats errorstat_OOM | sed 's/count=//')
      evicted=$(stat stats evicted_keys)
      cached=$(redis-cli --scan --pattern 'cache:*' 2>/dev/null | wc -l)
      llen_after=$(redis-cli LLEN queue:jobs)
      alive=$(probes_alive)

      if [ "${oom:-0}" -gt 0 ]; then
        echo "not yet: the cache warm had ${oom} writes refused with OOM. Redis reached the"
        echo "ceiling, found nothing it was permitted to evict, and failed the write rather"
        echo "than lose data — the right instinct, and the wrong outcome for a page cache."
        echo "Under a volatile-* policy the only candidates are keys that carry a TTL. Look"
        echo "at what $app writes and whether it ever tells Redis those pages"
        echo "are disposable."
        exit 1
      fi
      if [ "$rc" != "0" ]; then
        echo "not yet: $app exited $rc:"
        tail -3 /tmp/grader-cache-warm.log | sed 's/^/    /'
        exit 1
      fi
      # head closes the pipe on the first line, which SIGPIPEs the scan; without
      # the guard pipefail takes the whole check down without printing anything.
      sample=$(redis-cli --scan --pattern 'cache:*' 2>/dev/null | head -1 || true)
      ttl=-1
      [ -n "$sample" ] && ttl=$(redis-cli TTL "$sample" 2>/dev/null || echo -1)
      if [ "${ttl:--1}" -lt 60 ]; then
        echo "not yet: $sample expires in ${ttl}s. A TTL is what makes a key evictable, and"
        echo "one this short makes it evictable by being gone — the morning traffic arrives"
        echo "to an empty cache and rebuilds every page out of Postgres, which is the cost"
        echo "the cache exists to avoid. It has to outlive the gap between warms."
        exit 1
      fi
      if [ "${evicted:-0}" -lt 1 ] || [ "${cached:-0}" -lt 100 ]; then
        echo "not yet: the warm left ${cached} cache keys behind and Redis evicted ${evicted} keys"
        echo "reaching a $(( mm / 1048576 ))MB ceiling, so nothing about eviction was demonstrated. Enough"
        echo "pages have to be written to reach the ceiling, and enough of them have to still"
        echo "be there afterwards for the cache to be worth keeping — a TTL that empties it"
        echo "before the morning traffic arrives pays for the rebuild anyway."
        exit 1
      fi
      if [ "${alive:-0}" != "25" ] || [ "${llen_after:-0}" -lt "${llen_before:-0}" ]; then
        echo "not yet: the cache warm reached the ceiling and took the queue with it —"
        echo "${alive:-0} of 25 job hashes left, and queue:jobs went from ${llen_before} to ${llen_after}."
        echo "Redis evicted ${evicted} keys and some of them were not cache. Whatever is"
        echo "marking a key as disposable is marking the wrong keys."
        exit 1
      fi

      echo "PASS — Redis restarted with the queue intact, then evicted ${evicted} keys under"
      echo "the ceiling while all 25 jobs and ${cached} cached pages came through it."
