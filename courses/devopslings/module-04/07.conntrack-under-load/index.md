---
kind: lesson
title: "the connection tracker is filling up and nothing is connecting"
description: |
  A metrics shipper sends fire-and-forget UDP. No replies, no sessions, nothing
  to keep track of — and the kernel is keeping track of every packet anyway,
  for five minutes each. The box is idle and the table it uses to accept new
  connections is filling with flows that ended before they were recorded.
name: conntrack-under-load
slug: conntrack-under-load
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

      systemctl stop collector.service 2>/dev/null || true
      ip netns del collector 2>/dev/null || true
      ip link del to-coll 2>/dev/null || true
      nft delete table ip rawtrack 2>/dev/null || true
      conntrack -F >/dev/null 2>&1 || true

      install -d /opt/metrics

      ip netns add collector
      ip link add to-coll type veth peer name in0
      ip link set in0 netns collector
      ip addr add 10.67.0.1/24 dev to-coll
      ip link set to-coll up
      ip netns exec collector ip link set lo up
      ip netns exec collector ip addr add 10.67.0.5/24 dev in0
      ip netns exec collector ip link set in0 up
      ip netns exec collector ip route add default via 10.67.0.1

      sysctl -w net.ipv4.ip_forward=1 >/dev/null

      # The retention that turns a trickle into a problem. Five minutes per UDP
      # flow is not unusual on a gateway that was tuned for long-lived sessions
      # and never revisited.
      sysctl -w net.netfilter.nf_conntrack_udp_timeout=300 >/dev/null
      sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=300 >/dev/null

      cat > /opt/metrics/collector.py <<'PY'
      #!/usr/bin/env python3
      import socket
      s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
      # A burst of a few thousand small datagrams overruns the default receive
      # buffer long before the application gets to them, and the loss would be
      # read here as "the fix dropped the traffic". Give it room.
      s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
      s.bind(("0.0.0.0", 9125))
      n = 0
      while True:
          s.recvfrom(2048)
          n += 1
          open("/run/collector.count", "w").write(str(n))
      PY

      cat > /etc/systemd/system/collector.service <<'UNIT'
      [Unit]
      Description=statsd-style metrics collector
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/collector
      ExecStart=/usr/bin/python3 /opt/metrics/collector.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now collector.service >/dev/null 2>&1

      # The shipper. One metric, one packet, one fresh source port — which is
      # what almost every statsd client does.
      cat > /opt/metrics/ship.py <<'PY'
      #!/usr/bin/env python3
      import socket, sys, time
      n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
      for i in range(n):
          s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
          s.sendto(f"checkout.latency:{i}|ms".encode(), ("10.67.0.5", 9125))
          s.close()
          # A statsd client emits metrics as they happen rather than as fast as
          # the loop can run. Without this the burst outruns the collector and
          # the loss looks like a routing fault.
          time.sleep(0.0004)
      print(f"sent={n}")
      PY
      chmod +x /opt/metrics/ship.py /opt/metrics/collector.py

      conntrack -F >/dev/null 2>&1 || true
      sleep 1

      cat > /root/questions.txt <<'Q'
      This box ships metrics over UDP to a collector. Fire and forget: one
      packet per metric, a fresh source port each time, no reply expected and
      none sent.

      Watch what one burst costs:

        cat /proc/sys/net/netfilter/nf_conntrack_count
        /opt/metrics/ship.py 2000
        cat /proc/sys/net/netfilter/nf_conntrack_count

      Two thousand packets that are already finished leave two thousand entries
      in the connection tracking table, each held for five minutes. On a busy
      afternoon the table fills, and once it is full the kernel starts dropping
      the packets that would have created new entries — which includes the SYN
      of every genuine inbound connection. The box refuses connections while
      doing nothing.

      Make a 2000-packet burst cost fewer than 200 conntrack entries, with the
      collector still receiving the metrics.

      Two things the check will refuse: stopping the shipper, and stopping the
      collector. The traffic is legitimate. It is the bookkeeping that is not.

      Note: nf_conntrack_max is read-only in a container, so raising the ceiling
      is not available to you here — and on a real box it is the answer that buys
      a month and costs memory. Aim at the entries themselves.
      Q

      before=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
      /opt/metrics/ship.py 2000 >/dev/null
      sleep 1
      after=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
      echo "scenario ready — conntrack_count went $before -> $after for one burst"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # 1. Both ends of the legitimate traffic must still be running.
      if ! systemctl is-active --quiet collector.service; then
        echo "not yet: collector.service is not running."
        echo "         the metrics are wanted. Stopping the collector stops the"
        echo "         conntrack growth by stopping the thing that needed measuring."
        exit 1
      fi
      if [ ! -x /opt/metrics/ship.py ]; then
        echo "not yet: /opt/metrics/ship.py is gone or no longer executable."
        exit 1
      fi

      # 2. The measurement: a burst must not cost an entry per packet.
      conntrack -F >/dev/null 2>&1 || true
      sleep 1
      before=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
      c_before=$(cat /run/collector.count 2>/dev/null || echo 0)

      /opt/metrics/ship.py 2000 >/dev/null 2>&1 || true
      sleep 3

      after=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
      c_after=$(cat /run/collector.count 2>/dev/null || echo 0)
      delta=$((after - before))

      if [ "$delta" -ge 200 ]; then
        echo "not yet: 2000 packets still created $delta conntrack entries."
        echo "         count went $before -> $after"
        echo "         the tracker is recording one entry per source port for a flow"
        echo "         that has no second packet and no reply. Ask whether this"
        echo "         traffic needs tracking at all, and where in the pipeline that"
        echo "         decision can be made before an entry is allocated."
        exit 1
      fi

      # 3. And the metrics must still arrive — a rule that drops the traffic
      #    would also show a small delta.
      received=$((c_after - c_before))
      if [ "$received" -lt 1200 ]; then
        echo "not yet: the collector only received about $received of 2000 metrics."
        echo "         the entries stopped being created because the packets stopped"
        echo "         arriving. Untracked is not the same as dropped."
        exit 1
      fi

      echo "PASS — a 2000-packet burst now costs $delta conntrack entries and the"
      echo "       collector still received about $received of them."
