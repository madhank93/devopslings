---
kind: lesson
title: "the log file is empty and the answer is somewhere else"
description: |
  invoice-sync died an hour ago. Its own log file is zero bytes, which is not
  the same as nothing having been written anywhere. Four places on this box hold
  evidence about a dead process; exactly one of them has the message that says
  why. Learn where to look before you need to.
name: find-the-evidence
slug: find-the-evidence
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /var/log/invoice-sync /etc/invoice-sync /root/answers /var/lib/devopslings

      # The real message. It goes to stderr, which is where a service's last
      # words almost always go, and stderr belongs to journald.
      FATAL='FATAL: /etc/invoice-sync/rules.conf line 12: unexpected "}" — no rules loaded'
      printf '%s\n' "$FATAL" > /var/lib/devopslings/find-the-evidence.line
      echo journal > /var/lib/devopslings/find-the-evidence.where

      cat > /etc/invoice-sync/rules.conf <<'CONF'
      # invoice-sync rules
      match {
        vendor  = "acme"
        account = "4100"
      }
      match {
        vendor  = "globex"
        account = "4200"
      }
      match {
        vendor  = "initech"
        account = "4300"
      }}
      CONF

      cat > /usr/local/bin/invoice-sync <<SH
      #!/bin/bash
      # Opens its log file, then dies before it writes anything to it. This is
      # the ordinary shape of a startup failure: the log exists because the
      # process got far enough to create it, and is empty because it did not get
      # far enough to use it.
      exec 3>> /var/log/invoice-sync/app.log
      echo '$FATAL' >&2
      exit 78
      SH
      chmod 0755 /usr/local/bin/invoice-sync

      cat > /etc/systemd/system/invoice-sync.service <<'UNIT'
      [Unit]
      Description=Invoice synchroniser

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/invoice-sync
      UNIT

      systemctl daemon-reload
      systemctl start invoice-sync.service >/dev/null 2>&1 || true

      # Decoys, so that "look in /var/log" is a decision rather than the only
      # option. None of these mentions the parse failure.
      : > /var/log/invoice-sync/app.log
      cat > /var/log/invoice-sync/access.log <<'LOG'
      2026-08-03T02:58:11Z GET  /healthz 200
      2026-08-03T02:59:11Z GET  /healthz 200
      2026-08-03T03:00:11Z GET  /healthz 200
      LOG
      cat >> /var/log/syslog <<'LOG'
      Aug  3 03:00:04 box cron[311]: (root) CMD (/usr/local/bin/invoice-sync)
      Aug  3 03:00:12 box systemd[1]: invoice-sync.service: Consumed 12ms CPU time.
      LOG

      cat > /root/questions.txt <<'Q'
      invoice-sync failed. Two answers, each in its own file, nothing else in them:

        /root/answers/where   which of these four held the message that says WHY:
                                journal    the unit's journal
                                dmesg      the kernel ring buffer
                                logfile    a file under /var/log
                                fd         an open file descriptor of the process

        /root/answers/line    that message, copied exactly

      Q

      echo "scenario ready — invoice-sync.service failed at 03:00 and /var/log/invoice-sync/app.log is 0 bytes"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      want_where=$(cat /var/lib/devopslings/find-the-evidence.where)
      want_line=$(cat /var/lib/devopslings/find-the-evidence.line)

      if [ ! -s /root/answers/where ]; then
        echo "not yet: /root/answers/where is missing or empty"
        echo "         one of: journal, dmesg, logfile, fd"
        exit 1
      fi

      got_where=$(tr -d '[:space:]' < /root/answers/where | tr 'A-Z' 'a-z')
      if [ "$got_where" != "$want_where" ]; then
        case "$got_where" in
          logfile)
            echo "not yet: /var/log/invoice-sync/app.log is 0 bytes and access.log only has"
            echo "         health checks. The process opened its log and died before writing"
            echo "         to it — an empty log is evidence that it started, not that it was"
            echo "         silent."
            ;;
          dmesg)
            echo "not yet: the kernel has nothing to say here. dmesg is where you look when"
            echo "         the kernel acted on the process — an OOM kill, a segfault, a"
            echo "         hardware or filesystem error. This process exited on its own."
            ;;
          fd)
            echo "not yet: there is no process left to have file descriptors. That is a live"
            echo "         technique — it answers 'what is this running process writing to',"
            echo "         which is a different question from 'why did that one die'."
            ;;
          *)
            echo "not yet: '$got_where' is not one of journal, dmesg, logfile, fd"
            ;;
        esac
        exit 1
      fi

      if [ ! -s /root/answers/line ]; then
        echo "not yet: /root/answers/line is missing or empty — copy the message itself"
        exit 1
      fi

      # Compare on the substance, not on whitespace or a copied log prefix: a
      # student who pastes the whole journal line, timestamp and all, has still
      # found the right thing.
      norm() { tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'; }
      got_line=$(norm < /root/answers/line)
      key=$(printf '%s' "$want_line" | norm)

      case "$got_line" in
        *"$key"*) ;;
        *)
          echo "not yet: /root/answers/line does not contain the failure message"
          echo "         you have the right place; the message is the line invoice-sync"
          echo "         wrote to stderr just before it exited."
          exit 1
          ;;
      esac

      echo "PASS — the journal had it: $want_line"
---
