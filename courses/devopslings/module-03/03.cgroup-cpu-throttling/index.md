---
kind: lesson
title: "p99 spikes every few seconds and the CPU graph says 40%"
description: |
  pricing-api is slow in bursts. The box has idle cores, the process is not
  waiting on anything, and nothing in the application changed. There is a
  counter that explains it exactly, and it is not in top.
name: cgroup-cpu-throttling
slug: cgroup-cpu-throttling
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/pricing /var/lib/devopslings /root/answers
      rm -f /srv/pricing/latency.txt

      # A worker that does a fixed slice of CPU work per request and records how
      # long each one took in wall-clock terms.
      cat > /usr/local/bin/pricing-api <<'PY'
      #!/usr/bin/env python3
      import time

      def work():
          # ~15ms of arithmetic on an unthrottled core.
          x = 0
          for i in range(120_000):
              x += i * i
          return x

      with open("/srv/pricing/latency.txt", "w", buffering=1) as f:
          while True:
              t0 = time.monotonic()
              work()
              ms = (time.monotonic() - t0) * 1000
              f.write(f"{ms:.1f}\n")
              time.sleep(0.005)
      PY
      chmod 0755 /usr/local/bin/pricing-api

      # CPUQuota=20% with the default 100ms period. The work itself needs about
      # 15ms of CPU, so a request that starts late in a period gets suspended
      # until the next one — 80ms of doing nothing, on a box with idle cores.
      cat > /etc/systemd/system/pricing-api.service <<'UNIT'
      [Unit]
      Description=Pricing API worker

      [Service]
      ExecStart=/usr/local/bin/pricing-api
      CPUQuota=20%
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable pricing-api.service >/dev/null 2>&1 || true
      systemctl restart pricing-api.service >/dev/null 2>&1 || true
      sleep 8

      echo throttled > /var/lib/devopslings/cpu.cause

      cat > /root/questions.txt <<'Q'
      pricing-api's per-request latency spikes to 80-100ms in bursts. Each
      request is about 15ms of arithmetic. The box has idle cores and the
      process is not blocked on I/O, a lock or the network.

        /root/answers/cause   what is happening. One of:

          throttled     the kernel is suspending it despite idle CPU
          starved       other processes are outcompeting it for CPU
          blocked       it is waiting on I/O or a lock
          slowcode      the work itself became more expensive

      Then make its p99 request time under 40ms, sustained.

      pricing-api must keep a CPU limit — removing the bound entirely is not the
      fix. And do not make the work cheaper: the loop must stay as it is.
      Q

      echo "scenario ready — pricing-api p99 is $(sort -n /srv/pricing/latency.txt 2>/dev/null | awk '{a[NR]=$1} END {printf "%.0f", a[int(NR*0.99)]}')ms with idle CPU on the box"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      want=$(cat /var/lib/devopslings/cpu.cause)

      if [ ! -s /root/answers/cause ]; then
        echo "not yet: /root/answers/cause is missing or empty"
        echo "         one of: throttled, starved, blocked, slowcode"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/cause | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          starved)
            echo "not yet: nothing else is competing — the box is mostly idle. Starvation"
            echo "         would show as high total CPU with this process losing the race."
            ;;
          blocked)
            echo "not yet: a blocked process burns no CPU and sits in S or D state. This"
            echo "         one is on-CPU for its whole 15ms of work, then stops being"
            echo "         scheduled at all despite being runnable."
            ;;
          slowcode)
            echo "not yet: the loop is unchanged and does the same arithmetic every time."
            echo "         Time the same work outside the unit and compare."
            ;;
          *)
            echo "not yet: '$got' is not one of throttled, starved, blocked, slowcode"
            ;;
        esac
        exit 1
      fi

      if ! systemctl is-active --quiet pricing-api.service; then
        echo "not yet: pricing-api.service is not running"
        exit 1
      fi

      # A limit must remain. "Remove the quota" passes a latency check and gives
      # the service the whole machine.
      quota=$(systemctl show -p CPUQuotaPerSecUSec --value pricing-api.service 2>/dev/null || echo infinity)
      if [ "$quota" = "infinity" ] || [ -z "$quota" ]; then
        echo "not yet: pricing-api.service has no CPU limit any more"
        echo "         unbounded means this service can take the whole box during a spike."
        echo "         Keep a limit; make it one the workload can actually run inside."
        exit 1
      fi

      # Measure fresh: throw away the old samples and take new ones.
      : > /srv/pricing/latency.txt
      sleep 20

      n=$(wc -l < /srv/pricing/latency.txt)
      if [ "$n" -lt 100 ]; then
        echo "not yet: only $n samples in 20s — the worker is barely running"
        exit 1
      fi

      p99=$(sort -n /srv/pricing/latency.txt | awk '{a[NR]=$1} END {printf "%.1f", a[int(NR*0.99)]}')
      ok=$(awk -v p="$p99" 'BEGIN {print (p < 40) ? 1 : 0}')
      if [ "$ok" -ne 1 ]; then
        cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value pricing-api.service 2>/dev/null)"
        nr=$(awk '/nr_throttled/ {print $2}' "$cg/cpu.stat" 2>/dev/null || echo "?")
        echo "not yet: p99 is ${p99}ms over $n samples, and it needs to be under 40ms"
        echo "         nr_throttled for this unit is currently $nr"
        echo "         raising the quota, or shortening the period so the slice is handed"
        echo "         out more often, both reduce the stall. Removing the limit is not"
        echo "         an option the check accepts."
        exit 1
      fi

      cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value pricing-api.service 2>/dev/null)"
      nr=$(awk '/nr_throttled/ {print $2}' "$cg/cpu.stat" 2>/dev/null || echo 0)
      echo "PASS — cause identified as $want; p99 is ${p99}ms over $n samples with a CPU"
      echo "       limit still in place (nr_throttled: $nr)."
---
