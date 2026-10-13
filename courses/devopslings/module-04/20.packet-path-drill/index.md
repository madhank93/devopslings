---
kind: lesson
title: "the storefront cannot get its orders, and every layer says it is fine"
description: |
  The storefront's order lookups miss their 750ms budget. That is the whole
  ticket, every time — because the fault is drawn at random from five, each a
  different place on the kernel's packet path: a stale route that outranks the
  right one, a baseline that stopped the box forwarding, a NAT hairpin that lost
  its source rewrite, an AAAA record nobody routed, an accept queue the kernel
  capped. The drill is the order you follow the packet in.
name: packet-path-drill
slug: packet-path-drill
createdAt: "2026-10-08"
timingSensitive: true

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e
      D=/var/lib/packet-drill

      # ---- clean slate -------------------------------------------------
      systemctl stop orders.service lb-health.service shopnet.service 2>/dev/null || true
      systemctl reset-failed orders.service lb-health.service shopnet.service 2>/dev/null || true
      for u in orders lb-health shopnet; do
        rm -rf "/etc/systemd/system/$u.service.d" "/run/systemd/system/$u.service.d" \
               "/etc/systemd/system.control/$u.service.d" "/run/systemd/system.control/$u.service.d"
      done
      for ns in storefront orders; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del br-shop 2>/dev/null || true
      ip link del pub0 2>/dev/null || true
      ip route flush proto 199 2>/dev/null || true
      ip -6 route del fd00:72:1::/64 2>/dev/null || true
      nft delete table ip shopnat 2>/dev/null || true
      for t in $(nft list tables 2>/dev/null | awk '{print $2 ":" $3}'); do
        case "$t" in ip:nat) ;; *) nft delete table "${t%%:*}" "${t#*:}" 2>/dev/null || true ;; esac
      done
      rm -rf "$D" /etc/shopnet /etc/orders /opt/orders /opt/shop /etc/netns/storefront /etc/netns/orders \
             /etc/sysctl.d/30-shop-router.conf /etc/sysctl.d/60-cis-network.conf /root/answers/triage.md
      rm -f /etc/sysctl.d/9*.conf /etc/gai.conf
      # /etc/hosts is a bind mount in a container: rewrite it in place, never rename over it.
      grep -v 'orders\.internal' /etc/hosts > /root/.hosts.drill || true
      cat /root/.hosts.drill > /etc/hosts && rm -f /root/.hosts.drill
      sysctl -q -w net.ipv4.ip_forward=1
      # Docker turns br_netfilter on, which drags bridged frames through the ip
      # hooks and would un-NAT a hairpin by accident. An ordinary router does not.
      sysctl -q -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
      install -d "$D" /etc/shopnet /etc/orders /opt/orders /opt/shop /root/answers

      # ---- the segment -------------------------------------------------
      #
      #   storefront 10.72.0.6 ─┐                       ┌─ pub0 203.0.113.20 (orders.internal)
      #                         ├─ br-shop 10.72.0.1 ── box
      #   orders     10.72.0.5 ─┘   fd00:72::1/64       └─ eth0 172.31.0.10 (lab network)
      #
      # The storefront reaches orders through the published address, so every
      # lookup is DNAT'd by this box and sent back out the bridge it came in on.
      ip link add br-shop type bridge
      ip addr add 10.72.0.1/24 dev br-shop
      ip -6 addr add fd00:72::1/64 dev br-shop nodad
      ip link set br-shop up
      for pair in "storefront 6" "orders 5"; do
        set -- $pair
        ip netns add "$1"
        ip link add "veth-$1" type veth peer name eth0-in
        ip link set eth0-in netns "$1"
        ip link set "veth-$1" master br-shop
        ip link set "veth-$1" up
        ip netns exec "$1" ip link set lo up
        ip netns exec "$1" ip addr add "10.72.0.$2/24" dev eth0-in
        ip netns exec "$1" ip -6 addr add "fd00:72::$2/64" dev eth0-in nodad
        ip netns exec "$1" ip link set eth0-in up
        ip netns exec "$1" ip route add default via 10.72.0.1
        ip netns exec "$1" ip -6 route add default via fd00:72::1
      done
      ip link add pub0 type dummy
      ip addr add 203.0.113.20/32 dev pub0
      ip link set pub0 up
      # Allocated for orders in the IPAM sheet, routed to the publication
      # interface, and never given to anything: a packet sent there is gone.
      ip -6 route add fd00:72:1::/64 dev pub0

      echo "203.0.113.20    orders.internal" >> /etc/hosts

      # ---- configuration, as boot applies it -----------------------------
      cat > /etc/sysctl.d/30-shop-router.conf <<'CONF'
      # This box routes the shop segment.
      net.ipv4.ip_forward = 1
      CONF
      cat > /etc/sysctl.d/60-cis-network.conf <<'CONF'
      # cis-baseline 3.2: network parameters for hosts.
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.default.send_redirects = 0
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.tcp_syncookies = 1
      CONF

      cat > /etc/shopnet/routes <<'CONF'
      # Static routes shopnet.service installs at boot, one per line, written as
      # the arguments to `ip route add`.
      10.99.0.0/16 via 172.31.0.11 dev eth0
      CONF

      cat > /etc/shopnet/nat.nft <<'CONF'
      # NAT for the shop segment, loaded by shopnet.service at boot.
      table ip shopnat {
        chain pre {
          type nat hook prerouting priority -100; policy accept;
          # orders.internal is published on 203.0.113.20
          ip daddr 203.0.113.20 tcp dport 8080 dnat to 10.72.0.5:8080
        }
        chain post {
          type nat hook postrouting priority 100; policy accept;
          # the segment's own lookups of the published address leave by the
          # bridge they arrived on
          ip saddr 10.72.0.0/24 ip daddr 10.72.0.5 tcp dport 8080 ct status dnat masquerade
          # egress to the lab network
          ip saddr 10.72.0.0/24 oifname "eth0" masquerade
        }
      }
      CONF

      cat > /etc/shopnet/orders.sysctl <<'CONF'
      # Kernel settings for the orders network namespace, applied by
      # shopnet.service at boot.
      net.ipv4.tcp_fin_timeout = 30
      net.ipv4.ip_local_port_range = 20000 60999
      CONF

      cat > /usr/local/sbin/shopnet-up <<'SH'
      #!/bin/sh
      # shopnet-up — applies /etc/shopnet: routes (tagged proto 199), the NAT
      # table, and the orders namespace's sysctls. Re-running it replaces all three.
      set -e
      ip route flush proto 199 2>/dev/null || true
      sed 's/#.*//' /etc/shopnet/routes | while read -r r; do
        if [ -n "$r" ]; then ip route add $r proto 199; fi
      done
      nft delete table ip shopnat 2>/dev/null || true
      nft -f /etc/shopnet/nat.nft
      ip netns exec orders sysctl -q -p /etc/shopnet/orders.sysctl
      SH
      chmod 0755 /usr/local/sbin/shopnet-up

      cat > /etc/systemd/system/shopnet.service <<'UNIT'
      [Unit]
      Description=shop segment routes, NAT and namespace sysctls
      After=network.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/shopnet-up

      [Install]
      WantedBy=multi-user.target
      UNIT

      # ---- orders ---------------------------------------------------------
      cat > /etc/orders/orders.conf <<'CONF'
      # orders. Read once, at start.
      port = 8080
      backlog = 1024
      CONF

      cat > /opt/orders/orders.py <<'PY'
      import socket
      import time

      conf = {}
      for line in open("/etc/orders/orders.conf"):
          line = line.strip()
          if line and not line.startswith("#") and "=" in line:
              k, v = line.split("=", 1)
              conf[k.strip()] = v.strip()

      s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
      s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
      s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind(("::", int(conf["port"])))
      s.listen(int(conf["backlog"]))
      print("orders: listening on [::]:%s, backlog %s" % (conf["port"], conf["backlog"]), flush=True)

      # One lookup at a time, a few milliseconds each.
      while True:
          c, _ = s.accept()
          try:
              c.settimeout(2)
              c.recv(4096)
              time.sleep(0.003)
              c.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\norders-ok-2026\n")
          except OSError:
              pass
          finally:
              c.close()
      PY

      cat > /etc/systemd/system/orders.service <<'UNIT'
      [Unit]
      Description=orders lookup service
      After=shopnet.service

      [Service]
      NetworkNamespacePath=/run/netns/orders
      ExecStart=/usr/bin/python3 /opt/orders/orders.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      # ---- the storefront's view -------------------------------------------
      cat > /opt/shop/probe.py <<'PY'
      #!/usr/bin/env python3
      # N order lookups at once, as one page render makes them, each against the
      # storefront's 750ms budget. The HTTP client's connect timeout is 2s.
      import socket
      import sys
      import threading
      import time

      HOST, PORT = "orders.internal", 8080
      N = int(sys.argv[1]) if len(sys.argv) > 1 else 50
      BUDGET, CONNECT = 0.75, 2.0

      go = threading.Event()
      lock = threading.Lock()
      results = []


      def lookup(i):
          go.wait()
          t0 = time.monotonic()
          why, fam = None, "-"
          try:
              s = socket.create_connection((HOST, PORT), timeout=CONNECT)
              fam = "ipv6" if s.family == socket.AF_INET6 else "ipv4"
              s.sendall(b"GET /orders/%d HTTP/1.0\r\nHost: orders.internal\r\n\r\n" % i)
              body = b""
              while True:
                  b = s.recv(4096)
                  if not b:
                      break
                  body += b
              s.close()
              if b"orders-ok" not in body:
                  why = "bad response"
          except OSError as e:
              why = (e.strerror or str(e) or type(e).__name__).lower()
          dt = time.monotonic() - t0
          if why is None and dt > BUDGET:
              why = "over budget"
          with lock:
              results.append((why, fam, dt))


      threads = [threading.Thread(target=lookup, args=(i,)) for i in range(N)]
      for t in threads:
          t.start()
      go.set()
      for t in threads:
          t.join()

      ok = [r for r in results if r[0] is None]
      print("shop-probe: %d lookups of %s:%d at once, %dms budget each"
            % (N, HOST, PORT, BUDGET * 1000))
      print("  ok %d/%d   slowest %.2fs" % (len(ok), N, max(r[2] for r in results)))
      groups = {}
      for why, fam, dt in results:
          if why:
              groups.setdefault((why, fam), []).append(dt)
      for (why, fam), ts in sorted(groups.items(), key=lambda kv: -len(kv[1])):
          via = ", connected over " + fam if fam != "-" else ""
          print("  %4d  %-40s %.2fs-%.2fs" % (len(ts), why + via, min(ts), max(ts)))
      sys.exit(0 if len(ok) == N else 1)
      PY
      cat > /usr/local/bin/shop-probe <<'SH'
      #!/bin/sh
      # What the storefront sees: shop-probe [lookups], run from its namespace.
      exec ip netns exec storefront python3 /opt/shop/probe.py "$@"
      SH
      chmod 0755 /opt/shop/probe.py /usr/local/bin/shop-probe

      # ---- the red herring ------------------------------------------------
      # The retired edge balancer's health check, still aimed at orders' old
      # admin port. Every probe is answered with a reset, and it says so.
      cat > /usr/local/bin/lb-health <<'PY'
      #!/usr/bin/env python3
      import socket
      import time

      fails, last = 0, 0.0
      while True:
          try:
              socket.create_connection(("10.72.0.5", 8081), timeout=1).close()
              if fails:
                  print("lb-health: orders 10.72.0.5:8081 UP", flush=True)
              fails = 0
          except OSError as e:
              fails += 1
              if time.monotonic() - last > 15:
                  print("lb-health: orders 10.72.0.5:8081 DOWN (%s), %d consecutive failures"
                        % (e.strerror or e, fails), flush=True)
                  last = time.monotonic()
          time.sleep(0.25)
      PY
      chmod 0755 /usr/local/bin/lb-health
      cat > /etc/systemd/system/lb-health.service <<'UNIT'
      [Unit]
      Description=edge balancer health check for orders

      [Service]
      ExecStart=/usr/local/bin/lb-health
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      sysctl -q -p /etc/sysctl.d/30-shop-router.conf
      sysctl -q -p /etc/sysctl.d/60-cis-network.conf
      systemctl daemon-reload
      systemctl enable --now shopnet.service >/dev/null 2>&1
      systemctl enable --now orders.service lb-health.service >/dev/null 2>&1

      listening() {
        for _ in $(seq 1 40); do
          grep -q ':8080 ' <<< "$(ip netns exec orders ss -lnt 2>/dev/null)" && return 0
          sleep 0.25
        done
        return 1
      }
      listening || { echo "orders did not start listening"; exit 1; }

      # Everything works at this point. Prove it before breaking one thing, so a
      # scenario that failed to come up cannot pass for the seeded fault.
      healthy=""
      for _ in 1 2 3; do
        if shop-probe > "$D/healthy.out" 2>&1; then healthy=yes; break; fi
        sleep 1
      done
      if [ -z "$healthy" ]; then
        echo "the scenario did not come up healthy before the fault was seeded:"
        cat "$D/healthy.out"
        exit 1
      fi

      # What boot left behind, for the check to compare against.
      nft list tables > "$D/tables"
      ip netns exec orders ip -br addr show > "$D/orders-addrs"

      # ---- seed one fault --------------------------------------------------
      faults="route forward hairpin ipv6 backlog"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      case "$fault" in
        route)
          # Left over from the payments DMZ. More specific than the bridge's
          # own /24, so it wins for the bottom of the segment.
          printf '%s\n' '# payments DMZ, until the firewall migration' \
            '10.72.0.0/28 via 172.31.0.99 dev eth0' >> /etc/shopnet/routes
          systemctl restart shopnet.service
          ;;
        forward)
          # Sorts after 30-shop-router.conf, so it wins.
          printf '%s\n' '# 3.1.1: a host is not a router.' 'net.ipv4.ip_forward = 0' \
            >> /etc/sysctl.d/60-cis-network.conf
          sysctl -q -p /etc/sysctl.d/60-cis-network.conf
          ;;
        hairpin)
          # "Tidied" to the egress rule alone.
          python3 - <<'PY'
      p = "/etc/shopnet/nat.nft"
      s = open(p).read()
      old = ("    # the segment's own lookups of the published address leave by the\n"
             "    # bridge they arrived on\n"
             "    ip saddr 10.72.0.0/24 ip daddr 10.72.0.5 tcp dport 8080 ct status dnat masquerade\n")
      assert s.count(old) == 1
      open(p, "w").write(s.replace(old, ""))
      PY
          systemctl restart shopnet.service
          ;;
        ipv6)
          # The dual-stack rollout: a AAAA from the IPAM sheet, one hextet off.
          echo "fd00:72:1::5    orders.internal" >> /etc/hosts
          ;;
        backlog)
          printf '%s\n' '# matches the 1-vCPU canary' 'net.core.somaxconn = 8' >> /etc/shopnet/orders.sysctl
          systemctl restart shopnet.service
          systemctl restart orders.service
          listening || { echo "orders did not start listening"; exit 1; }
          ;;
      esac
      conntrack -F >/dev/null 2>&1 || true

      broke=""
      for _ in 1 2 3; do
        if ! shop-probe > "$D/broken.out" 2>&1; then broke=yes; break; fi
        sleep 1
      done
      if [ -z "$broke" ]; then
        echo "the $fault fault was seeded and the storefront's lookups still pass:"
        cat "$D/broken.out"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is the
      # storefront's lookups passing after the configuration is re-applied.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > "$D/state"
      sha256sum /opt/orders/orders.py /etc/orders/orders.conf /opt/shop/probe.py \
        /usr/local/bin/shop-probe /usr/local/sbin/shopnet-up /etc/systemd/system/shopnet.service \
        /etc/systemd/system/orders.service /usr/local/bin/lb-health \
        /etc/systemd/system/lb-health.service > "$D/sums"
      chmod -R go-rwx "$D"

      cat > /root/questions.txt <<'Q'
      The storefront's order lookups are missing their 750ms budget.

        shop-probe                 50 lookups at once, from the storefront's namespace

      Everything worked a moment ago, and exactly one thing was then broken —
      drawn at random from five.

        storefront   namespace, 10.72.0.6, looks up orders.internal:8080
        orders       namespace, 10.72.0.5, orders.service, listens on [::]:8080
        this box     routes the shop segment (br-shop, 10.72.0.1) and publishes
                     orders.internal on 203.0.113.20 with a DNAT rule

      Boot configuration:

        /etc/sysctl.d/                this box's kernel settings
        /etc/shopnet/routes           static routes  } applied by
        /etc/shopnet/nat.nft          the NAT table  } shopnet.service
        /etc/shopnet/orders.sysctl    orders' namespace kernel settings
        /etc/hosts                    orders.internal, for both namespaces

      1. Make the storefront's lookups meet their budget by repairing what was
         broken, where it was broken:

           - orders, its config, the probe and shopnet-up stay as they are
           - orders.internal stays 203.0.113.20, and the dual-stack rollout is
             not being rolled back
           - the check sets ip_forward to the kernel's boot default, re-applies
             /etc/sysctl.d, restarts shopnet.service and orders.service, and only
             then measures — so a fix has to be in configuration

      2. Write /root/answers/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the command or counter that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order you follow the
      packet in, not the answer.
      Q

      echo "scenario ready — one fault seeded, the storefront's lookups failing"
      sed 's/^/  /' "$D/broken.out"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      D=/var/lib/packet-drill
      digest=$(cat "$D/state" 2>/dev/null || true)
      fault=""
      for cand in route forward hairpin ipv6 backlog; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: $D/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi
      indent() { sed 's/^/         /'; }

      # ---- left as it was ------------------------------------------------
      bad=$(sha256sum -c --quiet "$D/sums" 2>/dev/null | sed 's/:.*//' || true)
      for path in $bad; do
        case "$path" in
          *lb-health*)
            echo "not yet: $path has changed. lb-health was never the fault;"
            echo "         put it back as it was." ;;
          *)
            echo "not yet: $path has changed. Nothing seeded was in orders, the probe,"
            echo "         or the script that applies /etc/shopnet. Put it back and repair"
            echo "         the configuration it applies." ;;
        esac
        exit 1
      done
      for u in shopnet orders lb-health; do
        if systemctl show -p DropInPaths --value "$u.service" | grep -q '/run/'; then
          echo "not yet: $u.service has a runtime drop-in under /run, which the next"
          echo "         boot forgets: $(systemctl show -p DropInPaths --value "$u.service")"
          exit 1
        fi
      done

      # ---- the red herring ----------------------------------------------
      if ! systemctl is-active --quiet lb-health.service; then
        echo "not yet: lb-health.service is not running."
        echo "         It is the edge balancer's health check, aimed at a port orders"
        echo "         stopped listening on long ago. A reset is a host saying nothing"
        echo "         listens there — about :8081, not about the storefront's :8080."
        echo "         It belongs to another team. Start it again."
        exit 1
      fi

      # ---- sidesteps that need no measurement -----------------------------
      brnf=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)
      if [ "$brnf" != 0 ]; then
        echo "not yet: net.bridge.bridge-nf-call-iptables is on again. It does make"
        echo "         lookups work, by dragging every bridged frame on the box through"
        echo "         netfilter: a machine-wide change standing in for one NAT rule."
        exit 1
      fi
      if [ -n "$(ls -A /etc/netns/storefront 2>/dev/null || true)" ]; then
        echo "not yet: /etc/netns/storefront overrides the storefront's view of /etc."
        echo "         orders.internal is in /etc/hosts, for both namespaces. Remove it."
        exit 1
      fi
      v4=$(ip netns exec storefront getent ahostsv4 orders.internal 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ' ' || true)
      if [ "$v4" != 203.0.113.20 ]; then
        echo "not yet: orders.internal's IPv4 address is '${v4:-nothing}' from the"
        echo "         storefront, not 203.0.113.20. The storefront uses the published"
        echo "         address; going around it is not repairing it."
        exit 1
      fi

      # ---- the symptom, live and after a boot -------------------------------
      live_ok=""
      shop-probe > "$D/live.out" 2>&1 && live_ok=yes
      fwd_live=$(cat /proc/sys/net/ipv4/ip_forward)
      smx_live=$(ip netns exec orders sysctl -n net.core.somaxconn 2>/dev/null || echo '?')

      # Boot starts from the kernel's defaults, then applies configuration.
      sysctl -q -w net.ipv4.ip_forward=0
      sysctl -q --system --pattern '^net\.ipv4\.ip_forward$' >/dev/null 2>&1 || true
      ip netns exec orders sysctl -q -w net.core.somaxconn=4096
      systemctl reset-failed shopnet.service orders.service 2>/dev/null || true
      if ! systemctl restart shopnet.service 2>/dev/null; then
        echo "not yet: shopnet.service failed applying /etc/shopnet:"
        journalctl -u shopnet.service -o cat -n 4 --no-pager 2>/dev/null | indent
        exit 1
      fi
      systemctl restart orders.service 2>/dev/null || true
      up=""
      for _ in $(seq 1 40); do
        if grep -q ':8080 ' <<< "$(ip netns exec orders ss -lnt 2>/dev/null)"; then up=yes; break; fi
        sleep 0.25
      done
      if [ -z "$up" ]; then
        echo "not yet: orders.service is not listening on :8080 after a restart:"
        journalctl -u orders.service -o cat -n 4 --no-pager 2>/dev/null | indent
        exit 1
      fi
      conntrack -F >/dev/null 2>&1 || true

      fwd=$(cat /proc/sys/net/ipv4/ip_forward)
      smx=$(ip netns exec orders sysctl -n net.core.somaxconn 2>/dev/null || echo 0)
      limit=$(ip netns exec orders ss -lnt 'sport = :8080' 2>/dev/null | awk 'NR==2{print $3}')
      # The longest prefix wins, so anything but the bridge's own /24 decides
      # where lookups for orders go.
      extra=$(ip route show match 10.72.0.5 2>/dev/null | grep -v '^default' \
                | grep -v '^10\.72\.0\.0/24 dev br-shop proto kernel' || true)

      out=""
      for _ in 1 2; do
        if out=$(shop-probe 2>&1); then out=""; break; fi
        sleep 1
      done
      if [ -n "$out" ] && [ -z "$live_ok" ]; then
        echo "not yet: the storefront's lookups still miss their 750ms budget."
        echo "         With the configuration re-applied and orders restarted:"
        printf '%s\n' "$out" | indent
        if { [ "$(sysctl -n net.core.somaxconn)" != 4096 ] || grep -qs somaxconn /etc/sysctl.d/*.conf; } \
           && [ -n "$limit" ] && [ "$limit" -lt 128 ]; then
          echo "         net.core.somaxconn is per network namespace. The box's is"
          echo "         $(sysctl -n net.core.somaxconn); orders listens in its own, where it is $smx."
        fi
        exit 1
      fi
      if [ -n "$out" ]; then
        echo "not yet: the lookups pass live and fail after a re-applied boot."
        echo "         With the configuration re-applied the way a boot would:"
        printf '%s\n' "$out" | indent
        if [ "$fwd" != 1 ]; then
          echo "         ip_forward stays $fwd with /etc/sysctl.d applied over the boot"
          echo "         default (it was $fwd_live running). Files that set it, in order:"
          grep -sH 'ip_forward' /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf \
            /etc/sysctl.conf 2>/dev/null | indent || true
        elif printf '%s\n' "$extra" | grep -q 'proto 199'; then
          echo "         /etc/shopnet/routes still installs a route for orders that is"
          echo "         more specific than the bridge's /24:"
          printf '%s\n' "$extra" | grep 'proto 199' | indent
        elif [ -z "$limit" ] || [ "$limit" -lt 128 ]; then
          echo "         orders' listener was granted a backlog of ${limit:-?}: re-applying"
          echo "         /etc/shopnet/orders.sysctl set net.core.somaxconn in its namespace"
          echo "         to $smx (it was $smx_live running)."
        elif ! grep -q 'ct status dnat masquerade' /etc/shopnet/nat.nft; then
          echo "         shopnet.service reloaded /etc/shopnet/nat.nft, and what it loads"
          echo "         does not rewrite the segment's own lookups:"
          conntrack -L -p tcp -d 203.0.113.20 --dport 8080 2>/dev/null | head -1 | indent || true
        fi
        echo "         A repair made in the running kernel is gone at the next boot."
        exit 1
      fi

      # ---- repaired in configuration, not around it ---------------------------
      if [ -n "$extra" ]; then
        echo "not yet: the lookups pass, but a route covering orders (10.72.0.5) that is"
        echo "         not the bridge's own is still installed:"
        printf '%s\n' "$extra" | indent
        if printf '%s\n' "$extra" | grep -vq 'proto 199'; then
          echo "         One added by hand outranks it until the next boot. Fix the file"
          echo "         that installs the wrong one: /etc/shopnet/routes."
        fi
        exit 1
      fi
      if [ -z "$(ip route show default)" ] || ! grep -q 'proto 199' <<< "$(ip route show 10.99.0.0/16)"; then
        echo "not yet: the default route, or /etc/shopnet/routes' 10.99.0.0/16, is gone."
        echo "         Both were right; take out the route that is wrong, not the table."
        exit 1
      fi
      base=$(awk '{print $2 ":" $3}' "$D/tables" | sort | paste -sd ' ')
      now=$(nft list tables 2>/dev/null | awk '{print $2 ":" $3}' | sort | paste -sd ' ')
      if [ "$now" != "$base" ]; then
        echo "not yet: nftables has tables boot did not create (boot: $base; now: $now)."
        echo "         shopnet.service loads /etc/shopnet/nat.nft; a rule added by hand"
        echo "         anywhere else is gone at the next boot."
        exit 1
      fi
      # Captured first: grep -q exiting early would SIGPIPE nft under pipefail.
      if ! grep -q 'dnat to 10.72.0.5:8080' <<< "$(nft list table ip shopnat 2>/dev/null)"; then
        echo "not yet: /etc/shopnet/nat.nft no longer publishes orders on 203.0.113.20."
        echo "         The publication was right; it is what the storefront uses."
        exit 1
      fi
      for k in all default eth0-in; do
        if [ "$(ip netns exec storefront sysctl -n net.ipv6.conf.$k.disable_ipv6 2>/dev/null || echo 0)" != 0 ]; then
          echo "not yet: IPv6 is disabled in the storefront's namespace ($k). That removes"
          echo "         the symptom by removing the protocol the rollout is adding."
          exit 1
        fi
      done
      v6=$(ip netns exec storefront getent ahosts orders.internal 2>/dev/null \
             | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u || true)
      if [ "$fault" = ipv6 ] && [ -z "$v6" ]; then
        echo "not yet: orders.internal has no AAAA any more. That removes the symptom"
        echo "         by rolling back the dual-stack rollout; the record was not the"
        echo "         problem — where it pointed was."
        exit 1
      fi
      for a in $v6; do
        body=$(ip netns exec storefront curl -s -m 1 -g "http://[$a]:8080/" 2>/dev/null || true)
        if ! printf '%s' "$body" | grep -q 'orders-ok'; then
          echo "not yet: the lookups pass, and orders.internal still resolves to $a,"
          echo "         where nothing answers from the storefront. Any client that tries"
          echo "         that address still pays its connect timeout; working around the"
          echo "         record does not make it answer."
          exit 1
        fi
      done
      now_addrs=$(ip netns exec orders ip -br addr show 2>/dev/null || true)
      if [ "$now_addrs" != "$(cat "$D/orders-addrs")" ]; then
        echo "not yet: orders' addresses have changed since boot:"
        printf '%s\n' "$now_addrs" | indent
        echo "         An address added by hand is gone at the next boot. Fix the record"
        echo "         that names the wrong one."
        exit 1
      fi
      cis=/etc/sysctl.d/60-cis-network.conf
      for k in net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_redirects net.ipv4.tcp_syncookies; do
        if ! grep -Eqs "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$cis"; then
          echo "not yet: $cis no longer sets $k."
          echo "         The baseline's other controls were never the fault. Override"
          echo "         the one setting that is wrong for a router, not the baseline."
          exit 1
        fi
      done
      if [ -z "$limit" ] || [ "$limit" -lt 128 ]; then
        echo "not yet: orders asks listen() for a backlog of 1024 and was granted"
        echo "         ${limit:-?}: net.core.somaxconn in its namespace is $smx after"
        echo "         /etc/shopnet/orders.sysctl was re-applied. The next burst overflows it."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty. Three lines:"
        echo "         cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      re_route='\b(routes?|routing table|longest.?prefix|more.?specific|stale|/28|172\.31\.0\.99)\b'
      re_forward='\b(ip_forward|forward(ing|ed|s)?|router)\b'
      re_hairpin='\b(hairpin\w*|masquerad\w*|snat|source nat|source address|nat (loopback|reflection))\b'
      re_ipv6='\b(aaaa|ipv6|v6|dual.?stack|fd00:72:1::5)\b'
      re_backlog='\b(somaxconn|backlog|accept queue|listen queue|listenoverflows|listendrops|overflow\w*)\b'
      case "$fault" in
        route)
          what="/etc/shopnet/routes gained 10.72.0.0/28 via 172.31.0.99, more specific than br-shop's /24, so lookups for orders went to a gateway that does not exist"
          c_re=$re_route
          e_re='ip route (get|show)|\b172\.31\.0\.99\b|/28\b|\bproto 199\b|\btraceroute\b|\bip neigh\w*|\bincomplete\b'
          e_say="ip route get 10.72.0.5 choosing via 172.31.0.99 dev eth0"
          d_re='\b(routes?|next.?hops?|gateways?|neigh\w*|arp|incomplete|unreachable)\b'
          d_say="ip route get for each backend resolving to an unexpected next hop, or neighbour entries going INCOMPLETE" ;;
        forward)
          what="60-cis-network.conf set net.ipv4.ip_forward = 0 and sorts after 30-shop-router.conf, so the box stopped forwarding the DNAT'd lookups"
          c_re=$re_forward
          e_re='ip_forward|/proc/sys/net/ipv4|\bsysctl\b|inaddrerrors|no route to host|ehostunreach|host unreachable|\bnstat\b'
          e_say="sysctl net.ipv4.ip_forward reading 0, or IpInAddrErrors climbing in nstat while the probe runs"
          d_re='\b(ip_forward|forward\w*|sysctl|unreachable|icmp|inaddrerrors|ehostunreach)\b'
          d_say="ip_forward on a box that routes, or ICMP host-unreachables / IpInAddrErrors" ;;
        hairpin)
          what="nat.nft lost the masquerade for the segment's own lookups of 203.0.113.20, so orders answered 10.72.0.6 directly and the storefront reset the reply it did not recognise"
          c_re=$re_hairpin
          e_re='\btcpdump\b|\bconntrack\b|syn-?ack|\brst\b|\breset\w*|nat\.nft|nft list|masquerad\w*|\bsrc=|10\.72\.0\.6'
          e_say="tcpdump on br-shop showing orders' SYN-ACK going straight to 10.72.0.6 and a reset back, or conntrack's reply tuple"
          d_re='\b(syn.?sent|syn-?acks?|rst|resets?|handshakes?|conntrack|hairpin|connect\w*|synthetic|probes?)\b'
          d_say="a synthetic lookup from inside the segment through the published address, or handshakes stuck in SYN_SENT" ;;
        ipv6)
          what="orders.internal gained a AAAA, fd00:72:1::5, that nothing holds; every lookup spent its connect timeout on IPv6 before falling back to IPv4"
          c_re=$re_ipv6
          e_re='\bgetent\b|\bahosts\w*|\baaaa\b|curl -6|\b-6\b|fd00:72:1::5|/etc/hosts|over ipv4|\bipv4\b|\b2\.0\d?s\b'
          e_say="getent ahosts orders.internal returning fd00:72:1::5, and the probe's lookups taking 2s and connecting over ipv4"
          d_re='\b(latency|p99|p95|duration|connect.?time|aaaa|ipv6|v6|slow|budget|elapsed|seconds?|ms|fallback)\b'
          d_say="connect latency, or a check that every AAAA a service publishes answers" ;;
        backlog)
          what="orders.sysctl set net.core.somaxconn = 8 in orders' namespace, so its 1024 backlog was capped at 8 and a burst overflowed the accept queue"
          c_re=$re_backlog
          e_re='\bnstat\b|listenoverflows|listendrops|\bss -\w*l\w*|send-q|recv-q|somaxconn|orders\.sysctl|netstat -s'
          e_say="ListenOverflows climbing in orders' namespace (nstat), or ss -lnt showing a Send-Q of 8"
          d_re='\b(listenoverflows|listendrops|overflow\w*|accept queue|backlog|recv-q|send-q|syn retrans\w*|retransmi\w*)\b'
          d_say="ListenOverflows per minute in the service's namespace, or Recv-Q against Send-Q on the listener" ;;
      esac

      fail=0
      named=0
      for re in "$re_route" "$re_forward" "$re_hairpin" "$re_ipv6" "$re_backlog"; do
        if printf '%s' "$a_cause" | grep -Eq "$re"; then named=$((named + 1)); fi
      done
      if [ "$named" -ge 3 ]; then
        echo "not yet: cause names $named different faults. One was seeded; say which,"
        echo "         and what about it broke the lookups."
        exit 1
      fi
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and the lookups meet their"
        echo "         budget, so something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before the storefront did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 0 for 5 minutes', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired in configuration: after a"
      echo "       re-applied boot the box forwards, routes and hairpins orders, the"
      echo "       name answers on both families, the listener holds its burst, and"
      echo "       lb-health is still complaining about a port nobody uses."
---
