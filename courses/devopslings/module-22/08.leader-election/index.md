---
kind: lesson
title: "Leader election: two schedulers, one job"
description: |
  web1 and web2 both run the scheduler, and only the leader may run the
  job. It works until the network splits — then both of them lead. Make
  leadership something etcd grants and takes back, so exactly one node runs
  the job through a partition and a crash.
name: leader-election
slug: leader-election
createdAt: "2026-10-16"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      etcdctl --endpoints=http://etcd1:2379 del --prefix scheduler/ >/dev/null
      mkdir -p /ha/scheduler
      cat > /ha/scheduler/job <<'SH'
      #!/bin/bash
      # The invoicing run. Charging a customer twice is the failure this
      # lesson is about, so every run is recorded: when, and on which node.
      echo "$(date +%s.%N | cut -c1-14) $(hostname)" >> /ha/scheduler/runs
      SH
      chmod +x /ha/scheduler/job
      : > /ha/scheduler/runs
      cat > /ha/app/scheduler.sh <<'SH'
      #!/bin/bash
      # Runs on web1 and on web2. Only the leader may call /ha/scheduler/job,
      # once a second. Saving this file restarts it on both nodes; its output
      # is in /ha/web1/scheduler.log and /ha/web2/scheduler.log.
      # A call that cannot reach etcd fails within two seconds. The outer
      # timeout is for `lease keep-alive --once`, which ignores --command-timeout.
      E="timeout 2 etcdctl --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 --dial-timeout=1s --command-timeout=1s"
      me=$(hostname)
      lease=""
      while :; do
        leader=$($E get scheduler/leader --print-value-only 2>/dev/null)
        if [ -z "$leader" ] || [ "$leader" = "$me" ]; then
          # Nobody leads, or I do: (re)claim the key under a 5-second lease.
          if [ -z "$lease" ] || ! $E lease keep-alive --once "$lease" >/dev/null 2>&1; then
            lease=$($E lease grant 5 2>/dev/null | awk '{ print $2 }')
            $E put scheduler/leader "$me" --lease="$lease" >/dev/null 2>&1
          fi
          /ha/scheduler/job
        fi
        sleep 1
      done
      SH
      sleep 4
      echo "scenario ready — the scheduler runs on both nodes; this is who ran the job:"
      echo
      tail -n 4 /ha/scheduler/runs
      echo
      echo "  the scheduler:        /ha/app/scheduler.sh   (runs on web1 and web2)"
      echo "  every run of the job: /ha/scheduler/runs"
      echo "  the leader key:       etcdctl --endpoints=http://etcd1:2379 get scheduler/leader"
      echo "  split a node off:     node cut web1 back    (and node heal web1 back)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      runs=/ha/scheduler/runs
      cut=""
      trap '[ -n "$cut" ] && node heal "$cut" back >/dev/null 2>&1; for n in web1 web2; do docker start "devopslings-ha-$n" >/dev/null 2>&1; done; true' EXIT

      # The grader's own copy of the job, whatever happened to the student's.
      mkdir -p /ha/scheduler
      cat > /ha/scheduler/job <<'SH'
      #!/bin/bash
      # The invoicing run. Charging a customer twice is the failure this
      # lesson is about, so every run is recorded: when, and on which node.
      echo "$(date +%s.%N | cut -c1-14) $(hostname)" >> /ha/scheduler/runs
      SH
      chmod +x /ha/scheduler/job

      if [ ! -s /ha/app/scheduler.sh ]; then
        echo "not yet: /ha/app/scheduler.sh is missing or empty, so no node runs the job."
        exit 1
      fi
      now() { date +%s.%N | cut -c1-14; }
      calc() { awk "BEGIN { printf \"%.1f\", $1 }"; }
      # Nodes that ran the job in (from, to], one per line.
      ran() { awk -v a="$1" -v b="$2" '$1 > a && $1 <= b { print $2 }' "$runs" | sort -u; }
      count() { awk -v a="$1" -v b="$2" -v n="$3" '$1 > a && $1 <= b && $2 == n' "$runs" | wc -l | tr -d ' '; }
      first() { awk -v a="$1" -v n="$2" '$1 > a && $2 == n { print $1; exit }' "$runs"; }
      # Exactly one node in the last 5 seconds; prints it.
      one_leader() {
        local t w
        t=$(now); w=$(ran "$(calc "$t - 5")" "$t")
        case $(grep -c . <<<"$w" || true) in
          1) echo "$w" ;;
          0) echo "not yet: $1, no node ran the job for 5 seconds." >&2; return 1 ;;
          *) echo "not yet: $1, web1 and web2 both ran the job within the same 5 seconds:" >&2
             tail -n 6 "$runs" | sed 's/^/         | /' >&2; return 1 ;;
        esac
      }

      : > "$runs"
      sleep 8
      leader=$(one_leader "with both nodes healthy") || exit 1
      other=$([ "$leader" = web1 ] && echo web2 || echo web1)
      echo "steady state: only $leader runs the job"

      # Partition the leader from etcd. It must stop; the other must take over.
      node cut "$leader" back >/dev/null
      cut=$leader
      t=$(now)
      sleep 20
      late=$(count "$(calc "$t + 1.5")" "$(now)" "$leader")
      took=$(first "$t" "$other")
      if [ "$late" -gt 0 ] && [ -n "$took" ]; then
        echo "not yet: $leader was cut off from etcd, and $other took over $(calc "$took - $t")s later."
        echo "         $leader went on running the job: $late more times in 20 seconds. Two leaders."
        echo "         A node that cannot reach etcd cannot know whether it still leads. Not knowing"
        echo "         has to mean not leading — before its lease can run out and be granted to someone else."
        exit 1
      fi
      if [ "$late" -gt 0 ]; then
        echo "not yet: $leader was cut off from etcd and kept running the job ($late times in 20 seconds)."
        echo "         It could not renew anything, yet it still acted as leader."
        exit 1
      fi
      if [ -z "$took" ]; then
        echo "not yet: $leader was cut off from etcd and stopped, but $other never took over in 20 seconds."
        echo "         A leader that disappears must lose leadership on its own, by a lease running out."
        exit 1
      fi
      echo "$leader cut off: it stopped, and $other took over after $(calc "$took - $t")s"
      node heal "$leader" back >/dev/null
      cut=""
      sleep 6
      now_leader=$(one_leader "after $leader rejoined") || exit 1
      echo "$leader back: only $now_leader runs the job"

      # Crash the current leader for longer than a lease: the other takes over,
      # and the crashed node comes back as a follower.
      survivor=$([ "$now_leader" = web1 ] && echo web2 || echo web1)
      t=$(now)
      docker kill "devopslings-ha-$now_leader" >/dev/null
      sleep 12
      if [ -z "$(first "$t" "$survivor")" ]; then
        echo "not yet: $now_leader crashed and $survivor did not take over within 12 seconds."
        exit 1
      fi
      docker start "devopslings-ha-$now_leader" >/dev/null
      for _ in $(seq 30); do curl -fsS --max-time 1 "http://$now_leader:8080/ping" >/dev/null 2>&1 && break; sleep 1; done
      sleep 8
      after=$(one_leader "after $now_leader came back") || exit 1
      if [ "$after" != "$survivor" ]; then
        echo "not yet: $now_leader came back from a crash and took the job back from $survivor, which"
        echo "         was leading and healthy. A node that restarts has no claim to anything it held before."
        exit 1
      fi
      echo "$now_leader crashed: $survivor took over, and kept the job when $now_leader came back"
      echo
      echo "PASS — one leader through a partition and a crash."
