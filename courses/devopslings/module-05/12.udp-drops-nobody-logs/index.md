---
kind: lesson
title: "every metric was sent, and the dashboard comes up a sixth short"
description: |
  The application sends a counter per request over UDP. The send never fails.
  The collector is up, logs nothing, and its dashboard shows less than the
  traffic the load balancer logged. Nobody logged a drop, because UDP has
  nobody whose job that is, except a kernel counter almost nobody reads.
name: udp-drops-nobody-logs
slug: udp-drops-nobody-logs
createdAt: "2026-10-13"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e
      L=/var/lib/udp-lesson

      # ---- clean slate -------------------------------------------------
      systemctl stop metrics-collector.service 2>/dev/null || true
      systemctl reset-failed metrics-collector.service 2>/dev/null || true
      rm -rf /opt/collector /etc/collector "$L"
      rm -f /etc/systemd/system/metrics-collector.service /usr/local/bin/send-burst
      install -d /opt/collector /etc/collector "$L"

      # ---- the collector -----------------------------------------------
      #
      # A statsd-style receiver. It asks for the buffer its config names and
      # takes what the kernel gives it without checking, which is what most
      # real ones do. Every 1000 counters it stops reading for ~20 ms to flush
      # its aggregates; the receive queue has to hold what arrives meanwhile.
      cat > /opt/collector/collector.py <<'PY'
      import configparser
      import http.server
      import socket
      import threading
      import time

      cfg = configparser.ConfigParser()
      cfg.read("/etc/collector/collector.conf")
      port = cfg.getint("listen", "port")
      rcvbuf = cfg.getint("listen", "rcvbuf_bytes")

      received = 0


      class Metrics(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = ("collector_received_total %d\n" % received).encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, *args):
              pass


      def flush_to_backend():
          time.sleep(0.02)


      threading.Thread(
          target=http.server.HTTPServer(("127.0.0.1", 9102), Metrics).serve_forever,
          daemon=True,
      ).start()

      sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
      sock.bind(("0.0.0.0", port))
      print("listening on udp/%d, rcvbuf requested %d" % (port, rcvbuf), flush=True)

      while True:
          sock.recv(2048)
          received += 1
          if received % 1000 == 0:
              flush_to_backend()
      PY

      cat > /etc/collector/collector.conf <<'CONF'
      [listen]
      port = 8125
      # Trimmed in the memory diet (OPS-2231): the collector keeps up with
      # traffic, so the queue only ever holds a handful of packets.
      rcvbuf_bytes = 16384
      CONF

      printf '[Unit]\nDescription=metrics collector (udp/8125)\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/python3 /opt/collector/collector.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/metrics-collector.service

      # ---- the sender --------------------------------------------------
      #
      # Paced at ~8000/s, so the only overflow is the one the flush pauses
      # cause; a bigger queue absorbs it on any host ceiling down to 212992.
      cat > /usr/local/bin/send-burst <<'PY'
      #!/usr/bin/env python3
      """Replay the 9am batch: 8000 request counters over about a second."""
      import socket
      import time

      s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      failed = 0
      for i in range(8000):
          try:
              s.sendto(b"api.requests:1|c|#route:/checkout,host:web-%d" % (i % 9),
                       ("172.31.0.10", 8125))
          except OSError:
              failed += 1
          if i % 40 == 39:
              time.sleep(0.005)
      print("sent 8000 counters, %d send errors" % failed)
      PY
      chmod 755 /usr/local/bin/send-burst
      sha256sum /opt/collector/collector.py /usr/local/bin/send-burst > "$L/code.sha256"

      systemctl daemon-reload
      systemctl enable --now metrics-collector.service >/dev/null 2>&1
      for _ in $(seq 1 20); do
        curl -s -m 1 http://127.0.0.1:9102/ 2>/dev/null | grep -q collector_received_total && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The checkout service sends one counter per request to the metrics
      collector on this box, over UDP port 8125. At 9am a batch job fires
      about 8000 requests in a second, and the dashboard shows a fraction of
      them. The load balancer's logs have all 8000.

      Replay the batch and read the collector's own count:

        curl -s http://127.0.0.1:9102/
        send-burst
        sleep 3; curl -s http://127.0.0.1:9102/

      send-burst reports zero send errors, and it is telling the truth. The
      collector is running and logs nothing. Its config is in
      /etc/collector/collector.conf.

      Make the collector receive all 8000 counters of a burst, and keep it that
      way after the collector or the box restarts.

      The collector's code (/opt/collector/collector.py) is a vendored binary
      in all but name: do not edit it, and do not slow down send-burst; it
      replays what the app really does. Switching the app to TCP is a project,
      not a fix.
      Q

      echo "scenario ready — every send succeeds, not all of them arrive"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      L=/var/lib/udp-lesson
      conf=/etc/collector/collector.conf

      if ! sha256sum -c --quiet "$L/code.sha256" >/dev/null 2>&1; then
        echo "not yet: /opt/collector/collector.py or /usr/local/bin/send-burst has"
        echo "         been changed. One is the vendor's code and the other replays"
        echo "         what the app sends. Put them back; the fix is in the collector's"
        echo "         config."
        exit 1
      fi

      if ! systemctl is-active --quiet metrics-collector.service; then
        echo "not yet: metrics-collector.service is not running."
        echo "         journalctl -u metrics-collector.service -n 20"
        exit 1
      fi

      count() {
        curl -s -m 2 http://127.0.0.1:9102/ 2>/dev/null | awk '/collector_received_total/{print $2}'
      }
      for _ in $(seq 1 20); do
        [ -n "$(count)" ] && break
        sleep 0.5
      done

      # ---- the burst ---------------------------------------------------
      #
      # Kernel counters are per network namespace; this box's are the ones the
      # collector's socket is in.
      rcvbuf_errors() { awk '/^Udp:/{getline; print $6}' /proc/net/snmp; }
      e0=$(rcvbuf_errors)
      c0=$(count); : "${c0:=0}"
      /usr/local/bin/send-burst >/dev/null 2>&1 || true
      prev=-1
      for _ in $(seq 1 30); do
        sleep 0.5
        c1=$(count); : "${c1:=0}"
        [ "$c1" = "$prev" ] && break
        prev=$c1
      done
      e1=$(rcvbuf_errors)
      got=$((c1 - c0))
      lost=$((e1 - e0))

      if [ "$got" -ge 8000 ] && [ "$lost" -eq 0 ]; then
        rb=$(ss -ulmn 'sport = :8125' 2>/dev/null | grep -o 'rb[0-9]*' | head -1 | tr -d rb)
        echo "PASS — 8000 of 8000 counters arrived and the kernel dropped none. The"
        echo "       socket queues ${rb:-?} bytes, set by the collector's own config."
        exit 0
      fi

      # What the socket has, against what the config would give a new one: the
      # kernel caps a request at net.core.rmem_max and doubles it.
      rb=$(ss -ulmn 'sport = :8125' 2>/dev/null | grep -o 'rb[0-9]*' | head -1 | tr -d rb)
      : "${rb:=0}"
      want=$(sed -n 's/^[[:space:]]*rcvbuf_bytes[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$conf" 2>/dev/null | tail -1)
      : "${want:=0}"
      cap=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)
      : "${cap:=$want}"
      fresh=$(( 2 * (want < cap ? want : cap) ))

      echo "not yet: the collector counted $got of 8000 counters from one burst."
      echo "         The kernel discarded $lost datagrams in the same window because the"
      echo "         socket's receive queue was full (UdpRcvbufErrors)."
      echo "         The collector's socket can queue $rb bytes:"
      echo "           ss -ulmn 'sport = :8125'"
      if [ "$rb" -lt "$fresh" ]; then
        echo "         The config now asks for $want, which would get a new socket $fresh."
        echo "         This socket is older than that: its buffer was sized when it was"
        echo "         created."
      elif [ "$want" -gt "$cap" ]; then
        echo "         The config asks for $want; the kernel capped it at net.core.rmem_max"
        echo "         ($cap). Inside a container that ceiling may belong to the host."
      else
        echo "         That is what the config's rcvbuf_bytes = $want gets. How long does the"
        echo "         collector stop reading, and how much arrives meanwhile?"
      fi
      exit 1
