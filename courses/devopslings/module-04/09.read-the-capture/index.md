---
kind: lesson
title: "one capture, three connections, three different failures"
description: |
  All three were reported as "it timed out". One never got a reply, one was
  refused outright, and one was throttled to a standstill by the machine that
  asked for the data. The packets say which is which, and they say it in the
  first few lines.
name: read-the-capture
slug: read-the-capture
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

      systemctl stop cap-svc.service 2>/dev/null || true
      ip netns del cap-svc 2>/dev/null || true
      ip link del to-cap 2>/dev/null || true
      rm -f /root/capture.pcap
      install -d /opt/cap /root/answers

      ip netns add cap-svc
      ip link add to-cap type veth peer name in0
      ip link set in0 netns cap-svc
      ip addr add 10.90.0.1/24 dev to-cap
      ip link set to-cap up
      ip netns exec cap-svc ip link set lo up
      ip netns exec cap-svc ip addr add 10.90.0.5/24 dev in0
      ip netns exec cap-svc ip link set in0 up

      # Port 9301: everything addressed to it is dropped on arrival. Nothing
      # listens, nothing refuses, nothing answers.
      ip netns exec cap-svc nft add table ip capdrop
      ip netns exec cap-svc nft 'add chain ip capdrop inp { type filter hook input priority 0 ; }'
      ip netns exec cap-svc nft add rule ip capdrop inp tcp dport 9301 drop

      # Port 9303: a server that accepts the connection and then never reads a
      # byte of it, with a deliberately small receive buffer so the effect shows
      # up in a second rather than a minute.
      cat > /opt/cap/slow.py <<'PY'
      #!/usr/bin/env python3
      import socket, time
      s = socket.socket()
      s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
      s.bind(("0.0.0.0", 9303)); s.listen(8)
      held = []
      while True:
          c, _ = s.accept()
          c.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
          held.append(c)          # accepted, and never read from
          time.sleep(3600)
      PY

      cat > /etc/systemd/system/cap-svc.service <<'UNIT'
      [Unit]
      Description=the far side of the capture
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/cap-svc
      ExecStart=/usr/bin/python3 /opt/cap/slow.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now cap-svc.service >/dev/null 2>&1
      for _ in $(seq 1 20); do
        ip netns exec cap-svc ss -lnt 2>/dev/null | grep -q ':9303' && break
        sleep 0.5
      done

      # Three client flows, captured together.
      cat > /opt/cap/flows.py <<'PY'
      #!/usr/bin/env python3
      import socket, time

      # 9301 — silently discarded
      a = socket.socket(); a.settimeout(6)
      try: a.connect(("10.90.0.5", 9301))
      except OSError: pass
      finally: a.close()

      # 9302 — nothing listening, and nothing filtering
      b = socket.socket(); b.settimeout(6)
      try: b.connect(("10.90.0.5", 9302))
      except OSError: pass
      finally: b.close()

      # 9303 — accepted, then never read
      c = socket.socket(); c.settimeout(6)
      try:
          c.connect(("10.90.0.5", 9303))
          payload = b"x" * 65536
          end = time.time() + 4
          while time.time() < end:
              c.send(payload)
      except OSError:
          pass
      finally:
          c.close()
      PY

      timeout 25 tcpdump -i to-cap -w /root/capture.pcap -s 128 \
        'tcp and (port 9301 or port 9302 or port 9303)' >/dev/null 2>&1 &
      cap_pid=$!
      sleep 2
      python3 /opt/cap/flows.py >/dev/null 2>&1 || true
      sleep 2
      kill "$cap_pid" 2>/dev/null || true
      wait "$cap_pid" 2>/dev/null || true

      cat > /root/answers/capture.md <<'ANS'
      # One line per flow. Replace every ? with your answer.
      #
      #   verdict=  retransmission | reset | zerowindow
      #   fault=    client | server | network
      #
      # "fault" means which end has to change something for this to stop
      # happening — not which end sent the last packet.

      flow-9301: verdict=? fault=?
      flow-9302: verdict=? fault=?
      flow-9303: verdict=? fault=?
      ANS

      cat > /root/questions.txt <<'Q'
      Three connections were opened to the same host, one after another, and all
      three were reported by the application as "connection timed out". They are
      not the same failure.

      The capture is at /root/capture.pcap. Read it:

        tcpdump -r /root/capture.pcap -nn
        tcpdump -r /root/capture.pcap -nn 'port 9301'

      For each flow, decide what the packets show and which end has to change
      something. Write your answers into /root/answers/capture.md, which already
      has the three lines and the allowed values.

      Useful flags in tcpdump output: [S] syn, [S.] syn-ack, [.] ack,
      [P.] push, [R] or [R.] reset, [F.] fin. The win N field is the receive
      window the sender of that packet is advertising.

      No configuration needs changing. This one is graded on the reading.
      Q

      echo "scenario ready — /root/capture.pcap has three flows"
      tcpdump -r /root/capture.pcap -nn 2>/dev/null | head -6 | sed 's/^/  /' || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      ans=/root/answers/capture.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      if [ ! -s /root/capture.pcap ]; then
        echo "not yet: /root/capture.pcap is gone — there is nothing left to read."
        exit 1
      fi

      fail=0
      while read -r port want_verdict want_fault; do
        line=$(grep -E "^flow-$port:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'flow-$port:' line in $ans"
          exit 1
        fi

        gv=$(printf '%s' "$line" | sed -n 's/.*verdict=\([A-Za-z]*\).*/\1/p' | tr 'A-Z' 'a-z')
        gf=$(printf '%s' "$line" | sed -n 's/.*fault=\([A-Za-z]*\).*/\1/p'   | tr 'A-Z' 'a-z')

        if [ -z "$gv" ]; then
          echo "not yet: flow-$port has no verdict yet"
          exit 1
        fi
        case "$gv" in
          retransmission|reset|zerowindow) ;;
          *) echo "not yet: flow-$port says verdict='$gv', which is not one of"
             echo "         retransmission, reset, zerowindow"; exit 1 ;;
        esac
        if [ -z "$gf" ]; then
          echo "not yet: flow-$port has no fault yet"
          exit 1
        fi
        case "$gf" in
          client|server|network) ;;
          *) echo "not yet: flow-$port says fault='$gf', which is not one of"
             echo "         client, server, network"; exit 1 ;;
        esac

        if [ "$gv" != "$want_verdict" ]; then
          fail=1
          echo "not yet: flow-$port — you said verdict=$gv."
          case "$port" in
            9301) echo "         Count the packets from the client and look at their flags."
                  echo "         The same one, several times, at growing intervals, and not"
                  echo "         a single packet back. Nobody refused it. Nobody answered." ;;
            9302) echo "         Look at what came back, and how fast. One packet, one flag,"
                  echo "         immediately. That is a host saying nothing is listening —"
                  echo "         it is not a timeout at all." ;;
            9303) echo "         The handshake completed and data flowed. Then look at the"
                  echo "         win field on the packets coming back from :9303 as the"
                  echo "         transfer goes on." ;;
          esac
        elif [ "$gf" != "$want_fault" ]; then
          fail=1
          echo "not yet: flow-$port — verdict is right, fault=$gf is not."
          case "$port" in
            9301) echo "         Neither end misbehaved. The client sent, the server never"
                  echo "         saw it. Something between them discarded the packets, and"
                  echo "         that is the thing that has to change." ;;
            9302) echo "         The reset is the server behaving correctly: it has no"
                  echo "         listener on that port and said so at once. Who chose the"
                  echo "         port?" ;;
            9303) echo "         The window belongs to the receiver. It shrank because the"
                  echo "         application on that end accepted the connection and then"
                  echo "         stopped reading from it." ;;
          esac
        fi
      done <<'EXPECT'
      9301 retransmission network
      9302 reset client
      9303 zerowindow server
      EXPECT

      if [ "$fail" -ne 0 ]; then
        exit 1
      fi

      echo "PASS — all three flows classified, with the end that has to change"
      echo "       named correctly for each."
