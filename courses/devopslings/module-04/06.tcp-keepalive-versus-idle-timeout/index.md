---
kind: lesson
title: "the pooled connection both ends still believe in"
description: |
  A connection sits idle in a pool. Something in the middle forgets it. Neither
  end is told, because there is nothing to tell — the middlebox does not send a
  reset, it simply stops having an opinion. The next request to borrow that
  connection is the one that fails.
name: tcp-keepalive-versus-idle-timeout
slug: tcp-keepalive-versus-idle-timeout
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

      systemctl stop pool-svc.service 2>/dev/null || true
      for ns in pool-client pool-svc; do ip netns del "$ns" 2>/dev/null || true; done
      for l in to-client to-svc; do ip link del "$l" 2>/dev/null || true; done
      nft delete table ip middlebox 2>/dev/null || true

      install -d /opt/pool /srv/pool

      # Client and server on different subnets, so this box genuinely routes
      # between them and is genuinely the middlebox.
      #
      #   pool-client 10.66.0.2  <-->  10.66.0.1 [box] 10.66.1.1  <-->  10.66.1.5 pool-svc
      mk() {
        ns=$1 veth=$2 boxaddr=$3 nsaddr=$4
        ip netns add "$ns"
        ip link add "$veth" type veth peer name in0
        ip link set in0 netns "$ns"
        ip addr add "$boxaddr/24" dev "$veth"
        ip link set "$veth" up
        ip netns exec "$ns" ip link set lo up
        ip netns exec "$ns" ip addr add "$nsaddr/24" dev in0
        ip netns exec "$ns" ip link set in0 up
        ip netns exec "$ns" ip route add default via "$boxaddr"
      }
      mk pool-client to-client 10.66.0.1 10.66.0.2
      mk pool-svc    to-svc    10.66.1.1 10.66.1.5

      sysctl -w net.ipv4.ip_forward=1 >/dev/null

      # The middlebox. A stateful firewall forwards packets that belong to a
      # flow it knows about, and a SYN that starts a new one. Anything else —
      # including data on a flow it has forgotten — is dropped on the floor.
      # No reset, no ICMP. Silence is the whole problem.
      nft add table ip middlebox
      nft 'add chain ip middlebox gate { type filter hook forward priority 0 ; policy drop ; }'
      nft add rule ip middlebox gate ct state established,related accept
      nft add rule ip middlebox gate ct state new tcp flags syn accept
      nft add rule ip middlebox gate ct state new meta l4proto udp accept
      nft add rule ip middlebox gate icmp type { echo-request, echo-reply } accept

      # How long it remembers an idle TCP flow. Fifteen seconds is aggressive
      # for teaching; a real load balancer or NAT gateway is usually 60 to 350,
      # and the application's pool almost never knows the number.
      sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=15 >/dev/null

      # The server. It answers, forever, and is never the fault here.
      cat > /opt/pool/server.py <<'PY'
      #!/usr/bin/env python3
      import socket, threading

      def serve(c):
          try:
              while True:
                  d = c.recv(1024)
                  if not d:
                      return
                  c.sendall(b"pooled-ok-2026\n")
          except OSError:
              pass
          finally:
              c.close()

      s = socket.socket()
      s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind(("0.0.0.0", 9000)); s.listen(64)
      while True:
          c, _ = s.accept()
          threading.Thread(target=serve, args=(c,), daemon=True).start()
      PY

      cat > /etc/systemd/system/pool-svc.service <<'UNIT'
      [Unit]
      Description=the service behind the pool
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/pool-svc
      ExecStart=/usr/bin/python3 /opt/pool/server.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now pool-svc.service >/dev/null 2>&1

      # Wait for the listener. A namespaced unit takes a moment longer to come
      # up than a plain one, and probing before it does produces a connection
      # refused that looks nothing like the fault being taught.
      for _ in $(seq 1 20); do
        ip netns exec pool-svc ss -lnt 2>/dev/null | grep -q ':9000' && break
        sleep 0.5
      done

      # The application's pool settings. This is the half of the fix that lives
      # in the application rather than in the kernel.
      cat > /etc/pool.conf <<'CONF'
      # Connection pool settings for the checkout service.
      keepalive=off
      CONF

      # The pool probe: borrow a connection, hold it idle, then use it — which
      # is exactly what a pool does between two quiet periods.
      cat > /opt/pool/probe.py <<'PY'
      #!/usr/bin/env python3
      import socket, sys, time

      IDLE = float(sys.argv[1]) if len(sys.argv) > 1 else 25.0

      cfg = {}
      for line in open("/etc/pool.conf"):
          line = line.strip()
          if line and not line.startswith("#") and "=" in line:
              k, v = line.split("=", 1)
              cfg[k.strip()] = v.strip()

      s = socket.socket()
      s.settimeout(10.0)
      s.connect(("10.66.1.5", 9000))

      if cfg.get("keepalive", "off").lower() in ("on", "true", "1", "yes"):
          s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

      s.sendall(b"warmup\n")
      s.recv(1024)

      time.sleep(IDLE)

      start = time.monotonic()
      try:
          s.sendall(b"request\n")
          reply = s.recv(1024).decode(errors="replace").strip()
      except OSError as e:
          print(f"idle={IDLE:.0f} outcome=FAILED after={time.monotonic()-start:.1f}s error={e}")
          sys.exit(1)
      print(f"idle={IDLE:.0f} outcome=OK after={time.monotonic()-start:.1f}s reply={reply}")
      PY
      chmod +x /opt/pool/probe.py

      cat > /root/questions.txt <<'Q'
      The checkout service keeps a pool of connections to the backend. After a
      quiet period, the first request on a borrowed connection fails. A retry
      opens a fresh connection and succeeds, so the dashboard shows a low error
      rate and nobody can reproduce it on demand.

      Reproduce it on demand:

        ip netns exec pool-client /opt/pool/probe.py 25

      That borrows a connection, holds it idle for 25 seconds, and then uses it.

      While it is idle, both ends still believe the connection is ESTABLISHED —
      check with `ss -tn` in either namespace. Neither end is wrong. Nothing
      between them agrees.

      Make the 25-second probe succeed, without opening a new connection and
      without shortening the idle period. Both the application and the kernel
      have a part in this; fixing one and not the other still fails.

      /etc/pool.conf is the application's configuration. The probe reads it.

      A successful reply contains pooled-ok-2026.
      Q

      echo "scenario ready — an idle pooled connection dies after about 15s"
      ip netns exec pool-client /opt/pool/probe.py 25 2>&1 | sed 's/^/  /' || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # 1. The application half: the socket has to ask for keepalives at all.
      #    Without SO_KEEPALIVE the kernel settings apply to nothing.
      if ! grep -qiE '^[[:space:]]*keepalive[[:space:]]*=[[:space:]]*(on|true|1|yes)' /etc/pool.conf; then
        echo "not yet: /etc/pool.conf still has keepalive disabled."
        echo "         TCP keepalive is off by default on every socket. The kernel"
        echo "         timers below do nothing until the application opts in."
        exit 1
      fi

      # 2. The kernel half, inside the client's own network namespace — these
      #    sysctls are per-namespace, so setting them on the box does nothing
      #    for a process running in pool-client.
      kt=$(ip netns exec pool-client sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo 7200)
      if [ "${kt:-7200}" -ge 15 ]; then
        echo "not yet: net.ipv4.tcp_keepalive_time is ${kt}s in the pool-client namespace."
        echo "         the connection is being forgotten before the first keepalive is"
        echo "         ever sent. The probe has to refresh the flow while the thing in"
        echo "         the middle is still willing to remember it."
        exit 1
      fi

      # 3. The middlebox must still be a middlebox. Widening its timeout or
      #    deleting its rules fixes the symptom by removing the constraint.
      est=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo 0)
      if [ "${est:-0}" -ne 15 ]; then
        echo "not yet: the middlebox idle timeout has been changed (now ${est}s)."
        echo "         in production that box belongs to the network team and its"
        echo "         timeout is not yours to raise. Survive it instead."
        exit 1
      fi
      if ! nft list table ip middlebox >/dev/null 2>&1; then
        echo "not yet: the middlebox ruleset has been deleted."
        exit 1
      fi

      # 4. The measurement.
      out=$(ip netns exec pool-client /opt/pool/probe.py 25 2>&1 || true)
      if ! printf '%s' "$out" | grep -q 'outcome=OK'; then
        echo "not yet: the 25-second idle probe still fails:"
        printf '%s\n' "$out" | sed 's/^/         /'
        exit 1
      fi
      if ! printf '%s' "$out" | grep -q 'pooled-ok-2026'; then
        echo "not yet: the probe returned without the expected reply:"
        printf '%s\n' "$out" | sed 's/^/         /'
        exit 1
      fi

      echo "PASS — the pooled connection survives 25 seconds idle across a middlebox"
      echo "       that forgets flows after 15, with the middlebox left as it was."
