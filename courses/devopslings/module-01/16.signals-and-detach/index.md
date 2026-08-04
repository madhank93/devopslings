---
kind: lesson
title: "the reindex that dies every time your laptop sleeps"
description: |
  A six-hour reindex, started over SSH, killed three times this week by a
  dropped connection. Appending `&` does not help and neither does closing the
  laptop more carefully. Know which signal arrives, and start the job so it
  never gets it.
name: signals-and-detach
slug: signals-and-detach
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/reindex /root/answers /var/lib/devopslings
      rm -f /srv/reindex/progress /srv/reindex/done

      # A long job that reports progress, so the check can tell "still alive"
      # from "still working".
      cat > /usr/local/bin/reindex <<'SH'
      #!/bin/bash
      # No signal handling of its own, on purpose: whether it survives is a
      # property of how it was started, not of what it does.
      i=0
      while [ "$i" -lt 100000 ]; do
        i=$((i + 1))
        echo "$i" > /srv/reindex/progress
        sleep 0.2
      done
      : > /srv/reindex/done
      SH
      chmod 0755 /usr/local/bin/reindex

      echo sighup > /var/lib/devopslings/signals.answer

      # Do NOT use `pkill -f /usr/local/bin/reindex` here. This script is passed
      # to the shell as an argument, so its own command line contains that path
      # (the `cat >` above), and pkill -f would match the setup script and kill
      # it halfway through. Match on argv[1] being exactly the script instead.
      for proc in /proc/[0-9]*; do
        pid=${proc#/proc/}
        [ "$pid" = "$$" ] && continue
        argv1=$(tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | sed -n '2p' || true)
        [ "$argv1" = "/usr/local/bin/reindex" ] && kill -9 "$pid" 2>/dev/null || true
      done

      cat > /root/questions.txt <<'Q'
      The reindex takes about six hours and keeps dying when the SSH session
      drops.

        /root/answers/signal   which signal the kernel delivers to the session's
                               processes when the terminal goes away. One of:
                                 sighup   sigint   sigterm   sigkill

      Then start /usr/local/bin/reindex so that it KEEPS RUNNING when that
      signal is delivered to it.

      The check finds your reindex process, sends it that signal, and then
      watches /srv/reindex/progress to confirm it is still working afterwards.
      Q

      echo "scenario ready — /usr/local/bin/reindex is not running; start it so it survives"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      want=$(cat /var/lib/devopslings/signals.answer)

      if [ ! -s /root/answers/signal ]; then
        echo "not yet: /root/answers/signal is missing or empty"
        echo "         one of: sighup, sigint, sigterm, sigkill"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/signal | tr 'A-Z' 'a-z')
      case "$got" in
        sighup|hup|1) got=sighup ;;
      esac
      if [ "$got" != "$want" ]; then
        case "$got" in
          sigint|int)
            echo "not yet: SIGINT is what Ctrl-C sends to the foreground process group."
            echo "         Nobody pressed anything here — the terminal went away."
            ;;
          sigterm|term)
            echo "not yet: SIGTERM is the polite shutdown request systemd and kill send."
            echo "         It is not what a vanishing terminal produces."
            ;;
          sigkill|kill|9)
            echo "not yet: SIGKILL cannot be caught or ignored, so no way of starting the"
            echo "         job would survive it — and this job clearly can survive, since"
            echo "         that is what you are being asked to arrange."
            ;;
          *)
            echo "not yet: '$got' is not one of sighup, sigint, sigterm, sigkill"
            ;;
        esac
        exit 1
      fi

      # Same hazard as in init_scenario: pgrep -f would match this very script,
      # whose command line mentions the path. A reindex process is bash running
      # the script, so argv[1] is exactly the script path and nothing else is.
      pid=""
      for proc in /proc/[0-9]*; do
        cand=${proc#/proc/}
        [ "$cand" = "$$" ] && continue
        argv1=$(tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | sed -n '2p' || true)
        if [ "$argv1" = "/usr/local/bin/reindex" ]; then pid=$cand; break; fi
      done
      if [ -z "$pid" ]; then
        echo "not yet: no reindex process is running — start /usr/local/bin/reindex"
        exit 1
      fi

      p1=$(cat /srv/reindex/progress 2>/dev/null || echo 0)
      sleep 2
      p2=$(cat /srv/reindex/progress 2>/dev/null || echo 0)
      if [ "${p2:-0}" -le "${p1:-0}" ]; then
        echo "not yet: reindex (PID $pid) exists but /srv/reindex/progress is not advancing"
        echo "         it has to actually be working, not merely present."
        exit 1
      fi

      # The event itself.
      kill -HUP "$pid" 2>/dev/null || true
      sleep 3

      if ! kill -0 "$pid" 2>/dev/null; then
        echo "not yet: reindex (PID $pid) died when it was sent SIGHUP"
        echo "         appending & puts a job in the background of the SAME session, and a"
        echo "         backgrounded job still receives the hangup. The job has to either"
        echo "         ignore that signal or not be in the session at all."
        exit 1
      fi

      p3=$(cat /srv/reindex/progress 2>/dev/null || echo 0)
      sleep 2
      p4=$(cat /srv/reindex/progress 2>/dev/null || echo 0)
      if [ "${p4:-0}" -le "${p3:-0}" ]; then
        echo "not yet: reindex survived the signal but stopped making progress"
        echo "         it is alive and no longer working — check it is not stopped or"
        echo "         blocked on a terminal that no longer exists."
        exit 1
      fi

      sid=$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
      echo "PASS — reindex (PID $pid, session $sid) took SIGHUP and kept working:"
      echo "       progress $p1 -> $p4."
---
