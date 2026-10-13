---
kind: lesson
title: "every metric was sent, and the dashboard counts one in twenty"
description: |
  The application sends a counter per request over UDP. The send never fails.
  The collector is up, its config asks for an 8 MB receive buffer, and its
  dashboard shows a small fraction of the traffic the load balancer logged.
  Nobody logged a drop, because UDP has nobody whose job that is — except a
  kernel counter almost nobody reads.
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
      # Any earlier attempt's persisted buffer size goes, so the box boots
      # with the Debian default again.
      for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        if [ -f "$f" ]; then sed -i '/net\.core\.rmem_\(max\|default\)/d' "$f"; fi
      done
      sysctl -qw net.core.rmem_max=212992
      sysctl -qw net.core.rmem_default=212992
      install -d /opt/collector /etc/collector "$L"

      # ---- the collector -----------------------------------------------
      #
      # A statsd-style receiver. It asks for the buffer its config names and
      # takes what the kernel gives it without checking — which is what most
      # real ones do. Parsing is deliberately not instant: a real collector
      # aggregates, tags and forwards, and none of that is free.
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
          if received % 50 == 0:
              time.sleep(0.01)
      PY
      sha256sum /opt/collector/collector.py | cut -d' ' -f1 > "$L/collector.sha256"

      cat > /etc/collector/collector.conf <<'CONF'
      [listen]
      port = 8125
      # Sized for peak: the 9am batch fires ~8k counters in well under a second.
      rcvbuf_bytes = 8388608
      CONF

      printf '[Unit]\nDescription=metrics collector (udp/8125)\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/python3 /opt/collector/collector.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/metrics-collector.service

      # ---- the sender --------------------------------------------------
      cat > /usr/local/bin/send-burst <<'PY'
      #!/usr/bin/env python3
      """Replay the 9am batch: 8000 request counters, as fast as the app sends them."""
      import socket

      s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      failed = 0
      for i in range(8000):
          try:
              s.sendto(b"api.requests:1|c|#route:/checkout,host:web-%d" % (i % 9),
                       ("172.31.0.10", 8125))
          except OSError:
              failed += 1
      print("sent 8000 counters, %d send errors" % failed)
      PY
      chmod 755 /usr/local/bin/send-burst

      systemctl daemon-reload
      systemctl enable --now metrics-collector.service >/dev/null 2>&1
      for _ in $(seq 1 20); do
        curl -s -m 1 http://127.0.0.1:9102/ 2>/dev/null | grep -q collector_received_total && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The checkout service sends one counter per request to the metrics
      collector on this box, over UDP port 8125. At 9am a batch job fires
      about 8000 requests in under a second, and the dashboard shows a small
      fraction of them. The load balancer's logs have all 8000.

      Replay the batch and read the collector's own count:

        curl -s http://127.0.0.1:9102/
        send-burst
        sleep 3; curl -s http://127.0.0.1:9102/

      send-burst reports zero send errors, and it is telling the truth. The
      collector is running, logs nothing, and its config already asks for an
      8 MB receive buffer (/etc/collector/collector.conf).

      Make the collector receive all 8000 counters of a burst, and keep it that
      way after the box reboots.

      The collector's code (/opt/collector/collector.py) is a vendored binary
      in all but name: do not edit it. Switching the app to TCP is a project,
      not a fix.
      Q

      echo "scenario ready — every send succeeds, most never arrive"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      L=/var/lib/udp-lesson
      WANT=16000000

      if [ "$(sha256sum /opt/collector/collector.py 2>/dev/null | cut -d' ' -f1)" != "$(cat "$L/collector.sha256" 2>/dev/null)" ]; then
        echo "not yet: /opt/collector/collector.py has been changed."
        echo "         It is the vendor's code, and you will lose the edit at the next"
        echo "         upgrade. Put it back; the fix is in what the kernel lets it have."
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

      rb=$(ss -ulmn 'sport = :8125' 2>/dev/null | grep -o 'rb[0-9]*' | head -1 | tr -d rb)
      : "${rb:=0}"

      if [ "$got" -lt 8000 ]; then
        echo "not yet: the collector counted $got of 8000 counters from one burst."
        echo "         The kernel discarded $lost datagrams in the same window because the"
        echo "         socket's receive queue was full (UdpRcvbufErrors)."
        if [ "$rb" -lt "$WANT" ]; then
          echo "         The collector's socket can queue $rb bytes:"
          echo "           ss -ulmn 'sport = :8125'"
          if [ "$(sysctl -n net.core.rmem_max)" -ge 8388608 ]; then
            echo "         The ceiling is high enough now. The buffer size is settled when"
            echo "         the socket is created — and this one was created before."
          else
            echo "         The config asked for 8388608. Something decided it gets less."
          fi
        fi
        exit 1
      fi

      # ---- and after a reboot ------------------------------------------
      #
      # What systemd-sysctl applies at boot, in the order it applies it; the
      # last assignment wins.
      boot=$(/usr/lib/systemd/systemd-sysctl --cat-config 2>/dev/null \
               | sed -n 's/^[[:space:]]*-\{0,1\}net\.core\.rmem_max[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | tail -1)
      : "${boot:=0}"
      if [ "$boot" -lt 8388608 ]; then
        echo "not yet: the burst arrives whole now — and at boot, net.core.rmem_max goes"
        if [ "$boot" -eq 0 ]; then
          echo "         back to the kernel default. Nothing under /etc/sysctl.d sets it."
        else
          echo "         back to $boot. That is what /etc/sysctl.d says."
        fi
        echo "         sysctl -w changes the running kernel and nothing else."
        exit 1
      fi

      echo "PASS — 8000 of 8000 counters arrived, the socket queues $rb bytes, and the"
      echo "       ceiling that allows it is set at boot."
