---
kind: lesson
title: "the load generator runs out of ports and blames the server"
description: |
  Two hundred requests succeed and everything after that fails to connect. The
  server is idle, its accept queue is empty, and it answers by hand instantly.
  Nothing is refusing the connections — they are never leaving this box, because
  it has no source port left to send them from.
name: ephemeral-port-exhaustion
slug: ephemeral-port-exhaustion
createdAt: "2026-08-20"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop rates-api.service 2>/dev/null || true
      ip netns del svc 2>/dev/null || true
      ip link del to-svc 2>/dev/null || true
      install -d /opt/load /opt/net /root/answers

      ip netns add svc
      ip link add to-svc type veth peer name svc0
      ip link set svc0 netns svc
      ip addr add 10.92.0.1/24 dev to-svc
      ip link set to-svc up

      ip netns exec svc sh -c '
        ip link set lo up
        ip addr add 10.92.0.9/24 dev svc0
        ip link set svc0 up
      '

      # ---- the service being hammered ----------------------------------
      #
      # HTTP/1.1 with a content length, so the server keeps the connection open
      # and it is the client that closes. That detail decides which end of the
      # connection is left holding TIME_WAIT, and therefore which end runs out
      # of ports.
      cat > /opt/net/rates.py <<'PY'
      import http.server

      BODY = b"rate=1.0034\n"


      class Rates(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_GET(self):
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(BODY)))
              self.end_headers()
              self.wfile.write(BODY)

          def log_message(self, *args):
              pass


      srv = http.server.ThreadingHTTPServer(("10.92.0.9", 8080), Rates)
      srv.request_queue_size = 128
      srv.serve_forever()
      PY

      printf '[Unit]\nDescription=rates API\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/svc\nExecStart=/usr/bin/python3 /opt/net/rates.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/rates-api.service
      systemctl daemon-reload
      systemctl enable --now rates-api.service >/dev/null 2>&1

      # ---- the load generator ------------------------------------------
      #
      # Shipped and checksummed; its behaviour comes from the config file next
      # to it. One connection per request unless it is told otherwise, which is
      # what almost every hand-written client does.
      cat > /opt/load/loadgen.py <<'PY'
      import http.client
      import sys

      HOST = "10.92.0.9"
      PORT = 8080
      CONF = "/etc/loadgen.conf"


      def settings():
          conf = {}
          try:
              for line in open(CONF):
                  line = line.strip()
                  if line and not line.startswith("#") and "=" in line:
                      key, value = line.split("=", 1)
                      conf[key.strip().lower()] = value.strip().lower()
          except OSError:
              pass
          return conf


      conf = settings()
      keepalive = conf.get("keepalive", "no") in ("yes", "true", "on", "1")
      count = int(sys.argv[1]) if len(sys.argv) > 1 else int(conf.get("requests", "400"))

      ok = 0
      failed = 0
      first = None
      conn = None

      for i in range(count):
          try:
              if conn is None:
                  conn = http.client.HTTPConnection(HOST, PORT, timeout=4)
              conn.request("GET", "/rate")
              resp = conn.getresponse()
              resp.read()
              ok += 1
              if not keepalive:
                  conn.close()
                  conn = None
          except OSError as exc:
              failed += 1
              if first is None:
                  first = (i + 1, str(exc))
              if conn is not None:
                  conn.close()
              conn = None

      print("ok=%d failed=%d" % (ok, failed))
      if first is not None:
          print("first failure at request %d: %s" % first)
      PY
      sha256sum /opt/load/loadgen.py | awk '{print $1}' > /opt/load/loadgen.py.sha256

      printf '#!/bin/sh\nexec /usr/bin/python3 /opt/load/loadgen.py "$@"\n' > /usr/local/bin/loadgen
      chmod 755 /usr/local/bin/loadgen

      cat > /etc/loadgen.conf <<'CONF'
      # rates-api load generator
      requests=400

      # Reuse one connection for every request instead of opening a new one.
      keepalive=no
      CONF

      # ---- the tuning nobody remembers doing ----------------------------
      #
      # 200 ports. A range this narrow is not something anyone sets on purpose
      # for a load generator; it arrives from a hardening baseline, a container
      # image, or a firewall audit that wanted a small range to allow through,
      # and it is invisible until something opens connections faster than
      # TIME_WAIT retires them.
      sysctl -qw net.ipv4.ip_local_port_range="32768 32967"
      sysctl -qw net.ipv4.tcp_tw_reuse=0

      for _ in $(seq 1 20); do
        curl -s -m 1 -o /dev/null http://10.92.0.9:8080/rate 2>/dev/null && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The rates load test has started failing on this box. It was fine last
      quarter and the code has not changed.

        $ loadgen 400
        ok=199 failed=201
        first failure at request 200: [Errno 99] Cannot assign requested address

      The first two hundred requests succeed and everything after that fails.
      The obvious suspect is the server at 10.92.0.9:8080, and it is idle:

        $ curl -s http://10.92.0.9:8080/rate
        rate=1.0034
        $ systemctl status rates-api --no-pager | head -3

      It answers by hand, instantly, while the load test is failing. Nothing in
      its journal. No refusals, no resets, no backlog.

      Three things to do.

      1. Make the same run complete cleanly:

           $ loadgen 400
           ok=400 failed=0

         /opt/load/loadgen.py is shipped and checksummed. /etc/loadgen.conf is
         yours.

      2. Leave the service alone. It is not the problem and it must still answer
         on 10.92.0.9:8080 when you are finished.

      3. Write /root/answers/ports.md, exactly two lines:

           connect_error: <what connect() actually said, in words>
           who_holds_time_wait: <client or server>

      The second one decides everything else, so work it out rather than guess:
      the end that closes a TCP connection first is the end that keeps the
      socket around afterwards, and this run has one of each.

        ss -tan state time-wait dst 10.92.0.9 | wc -l
        sysctl net.ipv4.ip_local_port_range
      Q

      echo "scenario ready — 200 requests work, the rest cannot find a port"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the load generator is the vendor's --------------------------
      want=$(cat /opt/load/loadgen.py.sha256 2>/dev/null || echo missing)
      have=$(sha256sum /opt/load/loadgen.py 2>/dev/null | awk '{print $1}')
      if [ "$want" != "$have" ]; then
        echo "not yet: /opt/load/loadgen.py has been edited."
        echo "         The generator is shipped and checksummed. Everything you need"
        echo "         is in /etc/loadgen.conf and in the kernel."
        exit 1
      fi

      # ---- let the previous run's sockets retire -----------------------
      #
      # A failed run leaves the whole range in TIME_WAIT for a minute, and while
      # it does, this box cannot open a connection to anything — including the
      # checks below. Waiting for the pressure to clear before grading is what
      # keeps a correct fix from being failed by the mess the last run left.
      for _ in $(seq 1 40); do
        tw=$(ss -tan state time-wait dst 10.92.0.9 2>/dev/null | grep -c 10.92.0.9 || true)
        [ "${tw:-0}" -le 20 ] && break
        sleep 2
      done

      # ---- the service is not the problem and must survive -------------
      body=""
      for _ in $(seq 1 5); do
        body=$(curl -s -m 5 http://10.92.0.9:8080/rate 2>/dev/null || true)
        echo "$body" | grep -q 'rate=' && break
        sleep 2
      done
      if ! echo "$body" | grep -q 'rate='; then
        echo "not yet: the rates API at 10.92.0.9:8080 no longer answers."
        echo "         It was never the fault. Whatever was changed took it out."
        exit 1
      fi

      out=$(loadgen 400 2>&1 || true)

      if ! echo "$out" | grep -q 'ok=400 failed=0'; then
        echo "not yet: loadgen 400 said:"
        printf '%s\n' "$out" | sed 's/^/           /'
        if echo "$out" | grep -qi 'cannot assign requested address'; then
          echo "         Still no source port. Nothing about that error involves the"
          echo "         server: connect() failed before a packet was sent. Either"
          echo "         stop consuming a port per request, or give the box more of"
          echo "         them."
          if [ "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)" = "1" ]; then
            echo
            echo "         tcp_tw_reuse is on and it did not save this run. It only lets"
            echo "         the kernel take back a TIME_WAIT socket that is more than a"
            echo "         second old, and this whole run finishes inside a second. It is"
            echo "         the standard advice and it is aimed at a steady drip of"
            echo "         connections, not a burst."
          fi
        fi
        exit 1
      fi

      # ---- the answers -------------------------------------------------
      if [ ! -s /root/answers/ports.md ]; then
        echo "not yet: /root/answers/ports.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/ports.md)
      err=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*connect_error[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)
      who=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*who_holds_time_wait[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)

      fail=0

      case "$err" in
        *"cannot assign requested address"*|*eaddrnotavail*|*"errno 99"*)
          ;;
        "")
          fail=1
          echo "not yet: no connect_error line in /root/answers/ports.md."
          ;;
        *refus*)
          fail=1
          echo "not yet: you said connect_error=$err."
          echo "         A refusal is an RST from the far end — something answered. This"
          echo "         error came from the local kernel, before anything was sent."
          ;;
        *"timed out"*|*timeout*)
          fail=1
          echo "not yet: you said connect_error=$err."
          echo "         A timeout means the packets went out and nothing came back."
          echo "         These requests failed instantly. Read the error the generator"
          echo "         printed."
          ;;
        *)
          fail=1
          echo "not yet: you said connect_error=$err."
          echo "         Run it with the fix removed and read the message verbatim, or"
          echo "           python3 -c 'import os; print(os.strerror(99))'"
          ;;
      esac

      case "$who" in
        *client*|*loadgen*|*"load generator"*|*box*)
          ;;
        "")
          fail=1
          echo "not yet: no who_holds_time_wait line in /root/answers/ports.md."
          ;;
        *server*|*api*)
          fail=1
          echo "not yet: you said who_holds_time_wait=$who."
          echo "         TIME_WAIT belongs to whichever end sends the first FIN. The"
          echo "         server keeps HTTP/1.1 connections open; the generator is the"
          echo "         one hanging up. Count them on each side while a run is going:"
          echo "           ss -tan state time-wait dst 10.92.0.9 | wc -l"
          echo "           ip netns exec svc ss -tan state time-wait | wc -l"
          ;;
        *)
          fail=1
          echo "not yet: you said who_holds_time_wait=$who."
          echo "         One word: client or server."
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — 400 requests, no failures, the generator unedited and the rates API"
      echo "       still answering. The ports were never the server's to give."
