---
kind: lesson
title: "clients time out and the server's log is empty"
description: |
  The application never sees these connections, so it cannot log them, so every
  investigation starts on the network. The kernel accepted them on the
  application's behalf, ran out of room to hold them, and dropped the rest —
  and it kept a counter about it that nobody reads.
name: accept-queue-overflow
slug: accept-queue-overflow
createdAt: "2026-08-08"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      systemctl stop queue-app.service 2>/dev/null || true
      install -d /opt/queue

      # A worker that is slow to call accept(). This is not exotic: a thread
      # pool with every thread busy, a GC pause, or a blocking call in the
      # accept loop all produce it.
      cat > /opt/queue/server.py <<'PY'
      #!/usr/bin/env python3
      import socket, time

      cfg = {}
      for line in open("/etc/queue.conf"):
          line = line.strip()
          if line and not line.startswith("#") and "=" in line:
              k, v = line.split("=", 1)
              cfg[k.strip()] = v.strip()
      backlog = int(cfg.get("backlog", "4"))

      s = socket.socket()
      s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind(("127.0.0.1", 9200))
      s.listen(backlog)

      held = []
      while True:
          c, _ = s.accept()
          held.append(c)
          time.sleep(0.2)
      PY

      cat > /etc/queue.conf <<'CONF'
      # Listener settings for the checkout front end.
      backlog=4
      CONF

      cat > /etc/systemd/system/queue-app.service <<'UNIT'
      [Unit]
      Description=checkout front end
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 /opt/queue/server.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload

      # The kernel's ceiling on any listener's accept queue. The application
      # asks for a backlog; it gets min(what it asked for, this).
      sysctl -w net.core.somaxconn=8 >/dev/null

      systemctl enable --now queue-app.service >/dev/null 2>&1
      sleep 1

      # The load: a hundred clients arriving together, which is a quiet second
      # for anything behind a load balancer.
      cat > /opt/queue/load.py <<'PY'
      #!/usr/bin/env python3
      import socket, sys

      N = int(sys.argv[1]) if len(sys.argv) > 1 else 100
      ok = fail = 0
      socks = []
      for _ in range(N):
          s = socket.socket()
          s.settimeout(3.0)
          try:
              s.connect(("127.0.0.1", 9200))
              ok += 1
              socks.append(s)
          except OSError:
              fail += 1
              s.close()
      print(f"connected={ok} failed={fail}")
      for s in socks:
          s.close()
      PY
      chmod +x /opt/queue/load.py /opt/queue/server.py

      cat > /root/questions.txt <<'Q'
      The checkout front end listens on 127.0.0.1:9200. Clients report
      connection timeouts under load. The application log is empty for the whole
      window — not errors, nothing at all, as if the requests never happened.

      Reproduce it:

        nstat -az | grep -E 'ListenOverflows|ListenDrops'
        /opt/queue/load.py 100
        nstat -az | grep -E 'ListenOverflows|ListenDrops'

      And look at the listener while that runs:

        ss -lnt 'sport = :9200'

      For a LISTEN socket those two columns are not what they are elsewhere:
      Recv-Q is how many completed connections are waiting to be accepted, and
      Send-Q is the maximum the queue can hold.

      Make all 100 connections succeed with no overflows counted.

      Two numbers cap that queue and the smaller one wins. Raising one and not
      the other changes nothing. Do not make the worker faster — the accept loop
      is standing in for a busy application, and a real one will not speed up
      because you asked.
      Q

      echo "scenario ready — 100 clients against a listener that cannot hold them"
      /opt/queue/load.py 100 2>&1 | sed 's/^/  /' || true
      ss -lnt 'sport = :9200' 2>/dev/null | sed 's/^/  /' || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # 1. The kernel ceiling.
      smx=$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)
      if [ "${smx:-0}" -lt 128 ]; then
        echo "not yet: net.core.somaxconn is $smx."
        echo "         every listener on this box is capped at that, no matter what"
        echo "         the application asks for."
        exit 1
      fi

      # 2. The application's request.
      blg=$(sed -n 's/^[[:space:]]*backlog[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' /etc/queue.conf | head -1)
      if [ -z "$blg" ] || [ "$blg" -lt 128 ]; then
        echo "not yet: /etc/queue.conf asks for backlog=${blg:-unset}."
        echo "         the kernel grants min(this, somaxconn). Raising the ceiling"
        echo "         alone leaves the application asking for a small queue."
        exit 1
      fi

      # 3. The listener must be running with the new value — a config change
      #    that was never restarted into is a config change that did nothing.
      if ! systemctl is-active --quiet queue-app.service; then
        echo "not yet: queue-app.service is not running."
        exit 1
      fi
      sendq=$(ss -lnt 'sport = :9200' 2>/dev/null | awk 'NR==2{print $3}')
      if [ -z "$sendq" ] || [ "$sendq" -lt 128 ]; then
        echo "not yet: the running listener's queue limit is ${sendq:-unknown}."
        echo "         listen() takes its backlog once, at startup. The process has"
        echo "         to be restarted before an edited config means anything."
        exit 1
      fi

      # 4. The worker must still be slow — speeding it up dodges the lesson.
      if ! grep -q 'time.sleep(0.2)' /opt/queue/server.py; then
        echo "not yet: the accept loop has been changed."
        echo "         it stands in for an application that is busy. A queue exists"
        echo "         precisely because the worker is not always ready."
        exit 1
      fi

      # 5. The measurement.
      before=$(nstat -az 2>/dev/null | awk '/TcpExtListenOverflows/{print $2}')
      before=${before:-0}
      out=$(/opt/queue/load.py 100 2>&1 || true)
      after=$(nstat -az 2>/dev/null | awk '/TcpExtListenOverflows/{print $2}')
      after=${after:-0}
      grew=$((after - before))

      if ! printf '%s' "$out" | grep -q 'connected=100 failed=0'; then
        echo "not yet: the load did not all connect: $out"
        echo "         overflows during that run: $grew"
        exit 1
      fi
      if [ "$grew" -ne 0 ]; then
        echo "not yet: all 100 connected but the kernel counted $grew overflow(s)."
        echo "         the queue is still being filled to its limit."
        exit 1
      fi

      echo "PASS — 100 simultaneous clients all connect with zero listen overflows,"
      echo "       against a worker that is exactly as slow as it was."
