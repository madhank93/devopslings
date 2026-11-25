---
kind: lesson
title: "four questions about a busy box"
description: |
  Something on this box is busy, and top shows four python processes taking
  turns at the top of the list. Four questions decide what to look at next:
  who makes the most syscalls, who opens what under /etc, who reads the most
  bytes, and how long the slowest read waits. Each one is a single bpftrace
  line. The grader re-runs your lines against a box it has reshuffled, so the
  lines have to be right, not just the answers.
name: bpftrace-one-liners
slug: bpftrace-one-liners
createdAt: "2026-11-23"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate ---------------------------------------------------
      systemctl stop busy.service 2>/dev/null || true
      systemctl reset-failed busy.service 2>/dev/null || true
      rm -rf /usr/local/lib/busy /etc/busy /var/lib/busy /root/oneliners \
             /etc/systemd/system/busy.service /root/answers/oneliners.md
      install -d /root/answers /root/oneliners /var/lib/busy /etc/busy
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      for f in alpha bravo charlie delta echo foxtrot golf hotel; do
        printf '# %s settings\nenabled = true\n' "$f" > "/etc/busy/$f.conf"
      done

      # ---- the workers ---------------------------------------------------
      # Four workers with fixed names and roles drawn from a seed: which one
      # makes the syscalls, which opens /etc files (and which ones), which reads
      # the bytes (and how many per second), and how long tailer's slow read
      # waits. A new seed changes every answer, which is how the grader tells a
      # working one-liner from a remembered answer.
      install -d /usr/local/lib/busy
      cat > /usr/local/lib/busy/worker.py <<'PY'
      import json, os, sys, threading, time

      name = sys.argv[1]
      seed = json.load(open("/var/lib/busy/seed.json"))
      with open("/proc/self/comm", "w") as f:
          f.write(name)

      def chatty():
          while True:
              for _ in range(20000):
                  os.getppid()
              time.sleep(0.1)

      def etc_opener(files):
          while True:
              for f in files:
                  with open("/etc/busy/" + f) as fh:
                      fh.read()
              time.sleep(0.5)

      def reader(per_sec):
          fd = os.open("/dev/zero", os.O_RDONLY)
          # Few large reads: counting read() calls instead of bytes points at tailer.
          chunk = 1048576
          while True:
              start = time.monotonic()
              left = per_sec
              while left > 0:
                  left -= len(os.read(fd, min(chunk, left)))
              time.sleep(max(0.0, 1.0 - (time.monotonic() - start)))

      def tailer(slow_ms):
          fifo = "/var/lib/busy/feed"
          def feed():
              with open(fifo, "w") as w:
                  while True:
                      for _ in range(100):
                          w.write("x\n"); w.flush()
                          time.sleep(0.01)
                      time.sleep(slow_ms / 1000.0)
          threading.Thread(target=feed, daemon=True).start()
          fd = os.open(fifo, os.O_RDONLY)
          while True:
              os.read(fd, 2)

      def idle():
          while True:
              time.sleep(0.25)
              os.stat("/var/lib/busy")

      jobs = []
      if seed["chatty"] == name:
          jobs.append(lambda: chatty())
      if seed["opener"] == name:
          jobs.append(lambda: etc_opener(seed["files"]))
      if seed["reader"] == name:
          jobs.append(lambda: reader(seed["bytes"]))
      if name == "tailer":
          jobs.append(lambda: tailer(seed["slow_ms"]))
      if not jobs:
          jobs.append(idle)
      for j in jobs[1:]:
          threading.Thread(target=j, daemon=True).start()
      jobs[0]()
      PY
      cat > /usr/local/lib/busy/run <<'SH'
      #!/bin/sh
      rm -f /var/lib/busy/feed && mkfifo /var/lib/busy/feed
      for w in ledger indexer mailer tailer; do
        python3 /usr/local/lib/busy/worker.py "$w" &
      done
      wait
      SH
      chmod 0755 /usr/local/lib/busy/run

      # Roles: chatty, opener and reader go to three different workers among
      # ledger, indexer and mailer, so no worker's comm answers two questions.
      cat > /usr/local/lib/busy/reseed <<'SH'
      #!/bin/sh
      python3 - "$@" <<'PY'
      import json, random, sys
      prev = {}
      try:
          prev = json.load(open("/var/lib/busy/seed.json"))
      except OSError:
          pass
      names = ["ledger", "indexer", "mailer"]
      confs = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
      while True:
          random.shuffle(names)
          s = {
              "chatty": names[0], "opener": names[1], "reader": names[2],
              "files": sorted(c + ".conf" for c in random.sample(confs, 3)),
              "bytes": random.choice([3, 4, 5, 6, 7, 8]) * 1048576,
              "slow_ms": random.choice([300, 400, 500, 600, 700, 800]),
          }
          if not prev or all(s[k] != prev[k] for k in s):
              break
      json.dump(s, open("/var/lib/busy/seed.json", "w"))
      PY
      SH
      chmod 0755 /usr/local/lib/busy/reseed
      /usr/local/lib/busy/reseed
      chmod 0600 /var/lib/busy/seed.json

      cat > /etc/systemd/system/busy.service <<'U'
      [Unit]
      Description=Four busy workers

      [Service]
      ExecStart=/usr/local/lib/busy/run
      KillMode=control-group
      U
      systemctl daemon-reload
      systemctl start busy.service

      cat > /root/questions.txt <<'Q'
      busy.service runs four workers: ledger, indexer, mailer and tailer. Answer
      four questions about them, each with one bpftrace program saved in
      /root/oneliners/:

        q1.bt  counts syscalls per process   -> which worker makes the most?
        q2.bt  prints each file opened under /etc, with the process that opened it
               -> which process opens /etc files, and which files?
        q3.bt  sums bytes returned by read() per process
               -> which worker reads the most, and how many bytes per second?
        q4.bt  measures each read() made by tailer and keeps the slowest
               -> how long does tailer's slowest read take, in milliseconds?

      Run each one for ten seconds or so and stop it with Ctrl-C. Then write
      /root/answers/oneliners.md:

        most-syscalls: <process>
        etc-opener: <process>
        etc-files: <file>, <file>, ...
        most-bytes: <process>
        bytes-per-second: <number>
        slowest-read-ms: <number>

      The grader re-runs your four programs after giving the workers new roles,
      new files, a new byte rate and a new slow read, and expects each program's
      output to show the new answer.
      Q

      echo "scenario ready — busy.service is running; questions in /root/questions.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      set -e
      ans=/root/answers/oneliners.md
      dir=/root/oneliners
      seed=/var/lib/busy/seed.json
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      for q in q1 q2 q3 q4; do
        if [ ! -s "$dir/$q.bt" ]; then
          echo "not yet: $dir/$q.bt is missing or empty. Save each one-liner as a"
          echo "         bpftrace program; /root/questions.txt says what each answers."
          exit 1
        fi
      done
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }
      s() { python3 -c "import json,sys; v=json.load(open('$seed'))[sys.argv[1]]; print(' '.join(v) if isinstance(v,list) else v)" "$1"; }
      num() { printf '%s' "$1" | tr -d ',_ ' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n 1 || true; }
      near() { python3 -c "import sys; a,b,t=map(float,sys.argv[1:]); sys.exit(0 if abs(a-b)<=t else 1)" "$@"; }

      # ---- the answers for the seed the student traced -------------------
      a=$(field most-syscalls)
      if ! printf '%s' "$a" | grep -Eq "\\b$(s chatty)\\b"; then
        echo "not yet: most-syscalls says '${a:-nothing}', and that is not the worker"
        echo "         making the most syscalls. Count them per comm with q1.bt and"
        echo "         read the largest entry, which bpftrace prints last."
        exit 1
      fi
      a=$(field etc-opener)
      if ! printf '%s' "$a" | grep -Eq "\\b$(s opener)\\b"; then
        echo "not yet: etc-opener says '${a:-nothing}', and that worker opens nothing"
        echo "         under /etc. Print comm next to each path q2.bt sees."
        exit 1
      fi
      a=$(field etc-files)
      for f in $(s files); do
        if ! printf '%s' "$a" | grep -Fq "${f%.conf}"; then
          echo "not yet: etc-files does not list every file the worker opens; one"
          echo "         is missing. Let q2.bt run for a few seconds — the worker"
          echo "         opens each file every half second."
          exit 1
        fi
      done
      n=$(printf '%s' "$a" | grep -oE '(alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel)' | sort -u | wc -l)
      if [ "$n" -gt 3 ]; then
        echo "not yet: etc-files lists $n files, and the worker opens three. Filter"
        echo "         q2.bt's output to that one process."
        exit 1
      fi
      a=$(field most-bytes)
      if ! printf '%s' "$a" | grep -Eq "\\b$(s reader)\\b"; then
        echo "not yet: most-bytes says '${a:-nothing}', and that is not the worker"
        echo "         reading the most. Sum read()'s return value per comm in q3.bt —"
        echo "         the return value, not the size asked for."
        exit 1
      fi
      a=$(num "$(field bytes-per-second)")
      want=$(s bytes)
      if [ -z "$a" ] || ! near "$a" "$want" "$((want / 5))"; then
        echo "not yet: bytes-per-second says '${a:-nothing}'. Divide q3.bt's total"
        echo "         for that worker by the seconds it ran, or print it every"
        echo "         second with interval:s:1."
        exit 1
      fi
      a=$(num "$(field slowest-read-ms)")
      want=$(s slow_ms)
      if [ -z "$a" ] || ! near "$a" "$want" $((want / 10 + 30)); then
        echo "not yet: slowest-read-ms says '${a:-nothing}'. Time each read() from"
        echo "         enter to exit for comm == \"tailer\", keep the max, and convert"
        echo "         nanoseconds to milliseconds. Run it for at least two seconds:"
        echo "         the slow read comes about once a second."
        exit 1
      fi

      # ---- re-run the one-liners against a fresh seed --------------------
      # The workers get new roles, files, rate and delay. Each saved program must
      # report the new answer; a program that prints a remembered one fails.
      # The traced seed goes back afterwards, so a second check grades the same
      # answers.
      cp "$seed" /var/lib/busy/seed.traced
      restore() {
        cp /var/lib/busy/seed.traced "$seed"
        systemctl restart busy.service 2>/dev/null || true
      }
      trap restore EXIT
      /usr/local/lib/busy/reseed
      systemctl restart busy.service
      sleep 2

      cpu0_note() {
        grep -q 'syscalls:sys_enter_' "$dir/$1.bt" || return 0
        echo "         If you are sure the program is right: on some kernels the"
        echo "         per-syscall sys_enter_* tracepoints reach bpftrace only for"
        echo "         syscalls made on CPU 0. tracepoint:raw_syscalls:sys_enter"
        echo "         sees every CPU — the unit shows how."
      }
      run_bt() {
        local out=/var/lib/busy/$1.out
        bpftrace "$dir/$1.bt" > "$out" 2>&1 &
        local bt=$!
        for _ in $(seq 120); do
          grep -q '^Attaching' "$out" && break
          kill -0 "$bt" 2>/dev/null || break
          sleep 0.5
        done
        if ! kill -0 "$bt" 2>/dev/null; then
          echo "not yet: bpftrace stopped running $dir/$1.bt. Its output:"
          tail -n 8 "$out" | sed 's/^/         /'
          exit 1
        fi
        sleep "$2"
        kill -INT "$bt" 2>/dev/null || true
        wait "$bt" 2>/dev/null || true
      }
      # The largest "@[key]: N" entry among busy's workers. bpftrace sees every
      # process on the kernel, and other containers can outdo a worker.
      top_key() {
        python3 - "$1" <<'PY'
      import re, sys
      workers = {"ledger", "indexer", "mailer", "tailer"}
      best, key = -1, ""
      for line in open(sys.argv[1], errors="replace"):
          m = re.match(r"^@\w*\[([^\]]+)\]:\s*(\d+)\s*$", line.strip())
          if not m:
              continue
          k = m.group(1).strip().strip('"')
          if k in workers and int(m.group(2)) > best:
              best, key = int(m.group(2)), k
      print(key)
      PY
      }
      run_bt q1 4
      got=$(top_key /var/lib/busy/q1.out)
      if [ "$got" != "$(s chatty)" ]; then
        echo "not yet: the grader gave the syscall-heavy role to $(s chatty) and"
        echo "         re-ran q1.bt; its largest entry was '${got:-none}'. q1.bt must"
        echo "         count syscalls per comm as they happen, printing @[comm]: N."
        cpu0_note q1
        exit 1
      fi

      run_bt q2 3
      for f in $(s files); do
        if ! grep -E "\\b$(s opener)\\b" /var/lib/busy/q2.out | grep -Fq "/etc/busy/$f"; then
          echo "not yet: the grader moved the /etc opens to $(s opener), opening"
          echo "         $(s files | sed 's/ /, /g'), and re-ran q2.bt."
          echo "         No line of its output names $(s opener) with /etc/busy/$f."
          echo "         Print comm and the path on one line for each open."
          cpu0_note q2
          exit 1
        fi
      done

      run_bt q3 4
      got=$(top_key /var/lib/busy/q3.out)
      if [ "$got" != "$(s reader)" ]; then
        echo "not yet: the grader made $(s reader) the heavy reader and re-ran q3.bt;"
        echo "         its largest entry was '${got:-none}'. Sum the bytes each read()"
        echo "         returned, keyed by comm."
        exit 1
      fi

      run_bt q4 4
      # Only map values ("@max: N", "@[tailer]: N") count; histogram bucket
      # labels are numbers too and would match by accident.
      want=$(s slow_ms)
      ok=""
      for v in $(grep -oE '^@[^:]*:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$' /var/lib/busy/q4.out | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*$' || true); do
        for scale in 1 1000 1000000; do
          if near "$v" "$((want * scale))" "$(( (want / 10 + 30) * scale ))"; then ok=yes; fi
        done
      done
      if [ -z "$ok" ]; then
        echo "not yet: the grader set tailer's slow read to about ${want} ms and re-ran"
        echo "         q4.bt; nothing in its output is near that. Its output:"
        tail -n 6 /var/lib/busy/q4.out | sed 's/^/         /'
        echo "         Time read() from enter to exit for comm == \"tailer\" only, and"
        echo "         keep the largest with max(), and filter the exit on read's syscall"
        echo "         number too."
        if grep -Eq '(^|[^>[:alnum:]_])(tid|pid)\b' "$dir/q4.bt"; then
          echo "         q4.bt uses bpftrace's tid/pid. Inside this box they can read 0"
          echo "         (get_ns_current_pid_tgid, retcode: -22), and when tailer's do, any"
          echo "         process's read ends its timing. Key on curtask->pid instead."
        fi
        cpu0_note q4
        exit 1
      fi

      echo "PASS — all four answers match, and all four one-liners found the new"
      echo "       answers after the grader reshuffled the workers."
