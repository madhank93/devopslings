---
kind: lesson
title: "two thousand processes you cannot kill, because they are already dead"
description: |
  The process table is filling with defunct entries and `kill -9` does nothing
  to any of them. It cannot: there is no process there to signal. The one
  process worth signalling is the one that is very much alive and not doing its
  job.
name: zombies-and-the-reaping-parent
slug: zombies-and-the-reaping-parent
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/jobrunner /root/answers /var/lib/devopslings
      rm -f /srv/jobrunner/completed

      # Forks a worker per job and never collects any of them. Each finished
      # child stays in the table as a zombie, holding its exit status for a
      # parent that is never going to ask.
      cat > /usr/local/bin/job-runner <<'PY'
      #!/usr/bin/env python3
      import os, sys, time

      print("job-runner: started", flush=True)
      done = 0
      while True:
          pid = os.fork()
          if pid == 0:
              # The worker. Does its bit of work and exits.
              time.sleep(0.05)
              os._exit(0)

          # The parent moves straight on to the next job. It never calls wait().
          done += 1
          with open("/srv/jobrunner/completed", "w") as f:
              f.write(str(done))
          time.sleep(0.05)
      PY
      chmod 0755 /usr/local/bin/job-runner

      cat > /etc/systemd/system/job-runner.service <<'UNIT'
      [Unit]
      Description=Background job runner

      [Service]
      ExecStart=/usr/local/bin/job-runner
      Restart=always
      RestartSec=1

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable job-runner.service >/dev/null 2>&1 || true
      systemctl restart job-runner.service >/dev/null 2>&1 || true

      # Let a visible pile build up.
      sleep 20

      echo alreadydead > /var/lib/devopslings/zombies.answer

      cat > /root/questions.txt <<'Q'
      `ps` is filling with <defunct> entries and kill -9 has no effect on them.

        /root/answers/why   why the signal does nothing. One of:

          alreadydead   there is no process left to receive it
          permissions   the signal is being sent by the wrong user
          blocked       the process has blocked or is ignoring that signal
          uninterruptible   it is in an uninterruptible sleep

      Then stop them accumulating. job-runner must still be running and still
      completing jobs when you are done — the check watches its counter advance
      and then counts the zombies it left behind.
      Q

      z=$(ps -eo stat= | grep -c '^Z' || true)
      echo "scenario ready — job-runner.service is running and $z defunct processes are on the box"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      want=$(cat /var/lib/devopslings/zombies.answer)

      if [ ! -s /root/answers/why ]; then
        echo "not yet: /root/answers/why is missing or empty"
        echo "         one of: alreadydead, permissions, blocked, uninterruptible"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/why | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          permissions)
            echo "not yet: you are root, and root can signal anything. Try it:"
            echo "           kill -9 <a defunct pid>; echo \$?"
            echo "         it returns 0 — the signal was accepted and nothing happened."
            ;;
          blocked)
            echo "not yet: SIGKILL cannot be blocked, caught or ignored by any process."
            echo "         If something could ignore it, that would be the answer; nothing"
            echo "         can."
            ;;
          uninterruptible)
            echo "not yet: an uninterruptible sleep shows as D, and it really does defer"
            echo "         signals. These are Z, which is a different state entirely —"
            echo "         look at what ps says the state letter is."
            ;;
          *)
            echo "not yet: '$got' is not one of alreadydead, permissions, blocked, uninterruptible"
            ;;
        esac
        exit 1
      fi

      if ! systemctl is-active --quiet job-runner.service; then
        echo "not yet: job-runner.service is not running"
        echo "         stopping it removes the zombies by removing the parent, which is"
        echo "         true and is not a fix — the jobs still have to run."
        exit 1
      fi

      pid=$(systemctl show -p MainPID --value job-runner.service)
      if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "not yet: job-runner has no main PID"
        exit 1
      fi

      # It has to still be doing the work.
      c1=$(cat /srv/jobrunner/completed 2>/dev/null || echo 0)
      sleep 3
      c2=$(cat /srv/jobrunner/completed 2>/dev/null || echo 0)
      if [ "${c2:-0}" -le "${c1:-0}" ]; then
        echo "not yet: job-runner is up but its completed counter is not advancing"
        echo "         ($c1 -> $c2). It has to keep running jobs, not just stop making"
        echo "         zombies."
        exit 1
      fi

      # Sustained load, then count what it left behind. Counting children of
      # this specific parent, so unrelated processes on the box cannot mask or
      # cause a failure.
      sleep 10
      zombies=$(ps -eo stat=,ppid= | awk -v p="$pid" '$1 ~ /^Z/ && $2 == p' | wc -l)
      if [ "$zombies" -gt 2 ]; then
        echo "not yet: job-runner (PID $pid) has $zombies defunct children after 10s of work"
        echo "         they are still not being collected. A parent has to reap what it"
        echo "         forks — or arrange for someone else to."
        exit 1
      fi

      total=$(ps -eo stat= | grep -c '^Z' || true)
      c3=$(cat /srv/jobrunner/completed 2>/dev/null || echo 0)
      echo "PASS — $((c3 - c1)) more jobs completed, $zombies defunct children left"
      echo "       (box-wide total: $total)."
---
