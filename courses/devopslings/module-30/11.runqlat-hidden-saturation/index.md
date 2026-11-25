---
kind: lesson
title: "CPU at 60%, and a 2 ms handler has a 40 ms p99"
description: |
  quote-api's handler takes two milliseconds and its p99 is many times that.
  The box has idle CPUs and the service is not throttled, so more CPU quota
  changes nothing. The time is spent runnable and waiting for a CPU — a wait
  no CPU-usage graph shows and runqlat measures directly. The work is
  measuring that wait and removing its cause without stopping the batch job
  that shares the service's CPUs.
name: runqlat-hidden-saturation
slug: runqlat-hidden-saturation
createdAt: "2026-11-23"
timingSensitive: true

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # The scenario pins explicit CPUs: two shared ones, and two more that must
      # exist for the fix to have somewhere to go.
      if [ "$(nproc)" -lt 4 ]; then
        echo "this lesson needs a Docker host with at least 4 CPUs; this one has $(nproc)"
        exit 1
      fi

      # ---- clean slate ---------------------------------------------------
      systemctl stop quote-api.service nightly-reindex.service 2>/dev/null || true
      systemctl reset-failed quote-api.service nightly-reindex.service 2>/dev/null || true
      rm -rf /opt/quote-api /etc/systemd/system/quote-api.service \
             /etc/systemd/system/quote-api.service.d \
             /etc/systemd/system/nightly-reindex.service \
             /etc/systemd/system/nightly-reindex.service.d \
             /usr/local/bin/nightly-reindex /root/answers/runqlat.md
      install -d /root/answers /opt/quote-api
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the service: ~2 ms of CPU per request ----------------------------
      cat > /opt/quote-api/server.py <<'PY'
      import http.server, time

      with open("/proc/self/comm", "w") as f:
          f.write("quote-api")

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              end = time.thread_time() + 0.002
              x = 0
              while time.thread_time() < end:
                  x += 1
              body = b"ok\n"
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *a):
              pass

      http.server.HTTPServer(("127.0.0.1", 8095), H).serve_forever()
      PY
      cat > /etc/systemd/system/quote-api.service <<'U'
      [Unit]
      Description=Quote API

      [Service]
      ExecStart=/usr/bin/python3 /opt/quote-api/server.py
      CPUAffinity=0 1
      U

      # ---- the neighbour: eight CPU-bound workers on the same two CPUs -----
      cat > /usr/local/bin/nightly-reindex <<'SH'
      #!/bin/sh
      # Rebuilds the search index. Deliberately CPU-bound; it must keep running.
      for i in 1 2 3 4 5 6 7 8; do
        sh -c 'while :; do :; done' &
      done
      wait
      SH
      chmod 0755 /usr/local/bin/nightly-reindex
      cat > /etc/systemd/system/nightly-reindex.service <<'U'
      [Unit]
      Description=Search index rebuild

      [Service]
      ExecStart=/usr/local/bin/nightly-reindex
      CPUAffinity=0 1
      U
      systemctl daemon-reload
      systemctl start nightly-reindex.service quote-api.service
      for _ in $(seq 40); do
        curl -fsS -o /dev/null http://127.0.0.1:8095/ 2>/dev/null && break
        sleep 0.25
      done

      cat > /root/questions.txt <<'Q'
      quote-api's handler burns about 2 ms of CPU, and its p99 is far above that.
      The box has idle CPUs, and quote-api is not throttled (cpu.stat's
      nr_throttled is 0).

      Measure how long quote-api waits for a CPU with runqlat, fix the cause, and
      measure again. nightly-reindex must keep running at full speed.

      Write /root/answers/runqlat.md:
        before-p99-ms: <runqlat p99 for quote-api before the fix>
        after-p99-ms: <runqlat p99 for quote-api after the fix>
        cause: <why quote-api waits>
      Q

      echo "scenario ready — quote-api's p99 is far above its 2 ms handler"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e
      ans=/root/answers/runqlat.md
      bound_ms=2
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }
      num() { printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n 1 || true; }
      b=$(num "$(field before-p99-ms)"); a=$(num "$(field after-p99-ms)")
      if [ -z "$b" ] || [ -z "$a" ]; then
        echo "not yet: give both before-p99-ms and after-p99-ms as numbers."
        exit 1
      fi
      if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)" "$b"; then
        echo "not yet: before-p99-ms says $b. Before the fix quote-api waited far"
        echo "         longer than that. trace its run-queue wait while requests run; p99 is"
        echo "         the bucket holding the 99th percent of samples."
        exit 1
      fi
      if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$a" "$b"; then
        echo "not yet: after-p99-ms ($a) is not below before-p99-ms ($b)."
        exit 1
      fi
      c=$(field cause)
      if printf '%s' "$c" | grep -Eq 'quota|throttl|limit'; then
        echo "not yet: cause says '$c'. quote-api's nr_throttled is 0: no quota holds"
        echo "         it back. It waits in a queue. Say which CPUs it may run on, and"
        echo "         what else runs there."
        exit 1
      fi
      if ! printf '%s' "$c" | grep -Eq 'affinit|pinn|cpuset|taskset' &&
         ! { printf '%s' "$c" | grep -Eq '\b(cpu|core)s?\b' &&
             printf '%s' "$c" | grep -Eq 'reindex|batch|neighbou?r'; }; then
        echo "not yet: cause says '${c:-nothing}'. Say which CPUs quote-api may run"
        echo "         on, and what else runs there."
        exit 1
      fi

      # ---- the neighbour still runs at full speed --------------------------
      if ! systemctl is-active -q nightly-reindex.service; then
        echo "not yet: nightly-reindex is not running. It has to finish tonight;"
        echo "         quote-api has to get its CPU time without stopping it."
        exit 1
      fi
      # Configuration, not a usage sample: on a shared host other workloads
      # take CPU time from both CPUs, so the batch's measured share drifts.
      bpid=$(systemctl show -P MainPID nightly-reindex.service)
      qpid=$(systemctl show -P MainPID quote-api.service)
      cg=/sys/fs/cgroup$(cut -d: -f3 "/proc/$bpid/cgroup")
      cpus() { sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "/proc/$1/status"; }
      # shellcheck disable=SC2046
      set -- $(python3 - "$(cpus "$bpid")" "$(cpus "$qpid")" <<'PY'
      import sys
      def parse(l):
          out = set()
          for part in l.split(","):
              a, _, b = part.partition("-")
              out.update(range(int(a), int(b or a) + 1))
          return out
      b, q = parse(sys.argv[1]), parse(sys.argv[2])
      print(len(b), len(q - b))
      PY
      )
      bn=$1 spare=$2
      workers=$(wc -l < "$cg/cgroup.procs")
      # cpu.max exists only once systemd enables the cpu controller for the unit.
      bmax=$(cat "$cg/cpu.max" 2>/dev/null || echo "max 100000")
      if [ "$bmax" != "max 100000" ] || [ "$bn" -lt 2 ] || [ "$workers" -lt 9 ]; then
        echo "not yet: nightly-reindex has less than it had: cpu.max '$bmax',"
        echo "         $bn CPUs allowed, $workers processes (was 'max 100000', 2, 9)."
        echo "         Slowing the batch down moves the problem, it does not fix it."
        exit 1
      fi
      for u in quote-api nightly-reindex; do
        ucg=/sys/fs/cgroup$(cut -d: -f3 "/proc/$(systemctl show -P MainPID "$u.service")/cgroup")
        w=$(cat "$ucg/cpu.weight" 2>/dev/null || echo 100)
        if [ "$w" != 100 ]; then
          echo "not yet: $u has cpu.weight $w (default 100). A heavier weight lets"
          echo "         quote-api jump the queue on two oversubscribed CPUs; the next"
          echo "         service pinned there still waits. Give quote-api CPUs that are"
          echo "         not busy."
          exit 1
        fi
        for p in $(cat "$ucg/cgroup.procs"); do
          n=$(ps -o ni= -p "$p" 2>/dev/null | tr -d ' ' || true)
          c=$(ps -o cls= -p "$p" 2>/dev/null | tr -d ' ' || true)
          if [ -n "$n" ] && { [ "$n" != 0 ] || [ "$c" != TS ]; }; then
            echo "not yet: $u runs at nice $n, class $c. Priority lets quote-api jump"
            echo "         the queue on two oversubscribed CPUs; the next service pinned"
            echo "         there still waits. Give quote-api CPUs that are not busy."
            exit 1
          fi
        done
      done

      # ---- quote-api's own wait for a CPU, under load ------------------------
      # runqlat.bt's measurement, keyed on quote-api's name: libbpf runqlat's -p
      # wants a host-namespace PID, and its -c filters on the waking task.
      out=$(mktemp)
      timeout -s INT 7 bpftrace -e "
        BEGIN { printf(\"ready\\n\"); }
        tracepoint:sched:sched_wakeup, tracepoint:sched:sched_wakeup_new { @q[args.pid] = nsecs; }
        tracepoint:sched:sched_switch {
          if (args.prev_state == 0) { @q[args.prev_pid] = nsecs; }
          \$ns = @q[args.next_pid];
          if (\$ns && args.next_comm == \"quote-api\") {
            @total = count();
            if (nsecs - \$ns >= $bound_ms * 1000000) { @slow = count(); }
          }
          delete(@q, args.next_pid);
        }
        END { clear(@q); }" > "$out" 2>&1 &
      bt=$!
      for _ in $(seq 60); do
        grep -q '^ready' "$out" && break
        kill -0 "$bt" 2>/dev/null || break
        sleep 0.25
      done
      python3 - <<'PY'
      import time, urllib.request
      end = time.time() + 4
      while time.time() < end:
          urllib.request.urlopen("http://127.0.0.1:8095/").read()
          time.sleep(0.005)
      PY
      kill -INT "$bt" 2>/dev/null || true
      wait "$bt" 2>/dev/null || true
      if ! grep -q '^ready' "$out"; then
        echo "not yet: the grader could not trace the run queue; this is the grader,"
        echo "         not your fix. Run verify again. bpftrace said:"
        sed 's/^/         /' "$out" | head -n 8
        rm -f "$out"
        exit 1
      fi
      total=$(sed -n 's/^@total: *//p' "$out"); slow=$(sed -n 's/^@slow: *//p' "$out")
      : "${total:=0}" "${slow:=0}"
      rm -f "$out"
      if [ "${total:-0}" -lt 50 ]; then
        echo "not yet: saw $total scheduling events for a task named quote-api while"
        echo "         the grader sent it requests. It must still run as quote-api."
        exit 1
      fi
      if [ "$spare" -lt 1 ]; then
        echo "not yet: every CPU quote-api may use is one nightly-reindex runs on, and"
        echo "         $slow of quote-api's $total waits for a CPU took ${bound_ms} ms or more."
        echo "         taskset -cp <pid> and systemctl show -P CPUAffinity say where each may"
        echo "         run. More CPU quota does not help — it is not throttled, it is queued."
        exit 1
      fi
      # Unfixed, most waits pass the bound. Fixed, a few still do when the host
      # is busy on quote-api's new CPUs, so the gate is p90, not p99.
      if [ $((slow * 10)) -gt "$total" ]; then
        echo "not yet: quote-api has CPUs nightly-reindex cannot use, yet $slow of its"
        echo "         $total waits for a CPU took ${bound_ms} ms or more. Something else"
        echo "         CPU-bound shares the CPUs it moved to."
        exit 1
      fi

      echo "PASS — quote-api has CPUs of its own; $slow of its $total waits for a CPU took"
      echo "       ${bound_ms} ms or more, and nightly-reindex keeps its two CPUs."
