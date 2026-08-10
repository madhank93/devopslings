---
kind: lesson
title: "every request stalls for five seconds and then succeeds"
description: |
  Nothing fails. Everything is slow by the same suspiciously round amount. The
  name resolves instantly, the service responds instantly, and between those two
  facts the client spends five seconds talking to an address that was answered
  correctly and routed nowhere.
name: ipv6-preferred-and-broken
slug: ipv6-preferred-and-broken
createdAt: "2026-08-07"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e

      systemctl stop dual-web.service 2>/dev/null || true
      # /etc/hosts is a bind mount in a container, so it cannot be replaced —
      # only rewritten in place. `sed -i` renames, and the rename fails.
      grep -v 'app\.internal' /etc/hosts > /tmp/hosts.new && cat /tmp/hosts.new > /etc/hosts
      ip -6 route del fd00:dead:beef::/64 2>/dev/null || true

      install -d /srv/dual /opt/client
      echo "dual-stack-2026" > /srv/dual/index.html

      # The service is dual-stack and healthy. It is not the fault.
      cat > /etc/systemd/system/dual-web.service <<'UNIT'
      [Unit]
      Description=a healthy dual-stack service
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind :: --directory /srv/dual
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now dual-web.service >/dev/null 2>&1

      # The name has both records. The A record is right. The AAAA record points
      # at an address in a prefix that was allocated, documented, and never
      # actually routed to this host.
      cat >> /etc/hosts <<'HOSTS'
      172.31.0.10        app.internal
      fd00:dead:beef::99 app.internal
      HOSTS

      # An on-link route with nobody home, plus a permanent neighbour entry so
      # that address resolution succeeds instantly and the SYN really goes out.
      # It is sent to a MAC address that does not exist, so nothing ever
      # answers and the connect burns the client's full timeout — five seconds,
      # every time, which is what makes this look like latency and not an error.
      # Without the neighbour entry the failure would come back in about three
      # seconds as address resolution giving up, which is a different symptom.
      ip -6 route add fd00:dead:beef::/64 dev eth0
      ip -6 neigh replace fd00:dead:beef::99 lladdr 02:00:00:00:00:99 dev eth0 nud permanent

      # The application. It resolves the name and connects, like most clients
      # that are not curl: address family order comes from getaddrinfo and the
      # first address gets a full connect timeout before anything else is tried.
      cat > /opt/client/fetch.py <<'PY'
      #!/usr/bin/env python3
      import socket, sys, time

      HOST, PORT, TIMEOUT = "app.internal", 8080, 5.0

      start = time.monotonic()
      body = None
      for fam, _t, _p, _c, sa in socket.getaddrinfo(HOST, PORT, type=socket.SOCK_STREAM):
          s = socket.socket(fam, socket.SOCK_STREAM)
          s.settimeout(TIMEOUT)
          try:
              s.connect(sa)
              s.sendall(b"GET / HTTP/1.0\r\nHost: app.internal\r\n\r\n")
              # Read to EOF. One recv() returns whatever happens to have
              # arrived, which on a bad day is the headers and no body.
              chunks = []
              while True:
                  b = s.recv(4096)
                  if not b:
                      break
                  chunks.append(b)
              body = b"".join(chunks).decode(errors="replace")
              break
          except OSError:
              continue
          finally:
              s.close()
      elapsed = time.monotonic() - start

      print(f"elapsed={elapsed:.2f}")
      print(body.rsplit("\r\n\r\n", 1)[-1].strip() if body else "NO-RESPONSE")
      sys.exit(0 if body else 1)
      PY
      chmod +x /opt/client/fetch.py
      sleep 1

      cat > /root/questions.txt <<'Q'
      The application fetches http://app.internal:8080/ on every request:

        /opt/client/fetch.py

      It works. It takes five seconds, every single time, and it took
      milliseconds last month.

      Things that have already been ruled out:

        - resolution is instant       getent hosts app.internal
        - the service is instant      curl http://172.31.0.10:8080/
        - nothing is being dropped    the request never reaches the wire at all
                                      during the five seconds

      Make the fetch complete in under two seconds.

      Two things the check will refuse: turning IPv6 off on this box, and
      deleting the AAAA record so the name is IPv4-only. Both make the symptom
      go away. Neither is a fix you could defend the day the network is v6-only.

      The service serves a page containing dual-stack-2026.
      Q

      echo "scenario ready — /opt/client/fetch.py takes about five seconds"
      /opt/client/fetch.py 2>&1 | sed 's/^/  /' || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # 1. IPv6 must still be enabled. Switching it off is the popular answer
      #    and it is a decision to stop supporting half the internet.
      dis=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)
      if [ "$dis" != "0" ]; then
        echo "not yet: IPv6 is disabled on this box (disable_ipv6=$dis)."
        echo "         that removes the symptom by removing the protocol. The next"
        echo "         network that is v6-only removes the service instead."
        exit 1
      fi

      # 2. The name must still have a AAAA record. Deleting it is the same
      #    retreat, one layer up.
      if ! getent ahostsv6 app.internal 2>/dev/null | grep -q ':'; then
        echo "not yet: app.internal no longer resolves to any IPv6 address."
        echo "         the record was not the problem — where it pointed was."
        exit 1
      fi

      # 3. That address must actually be reachable, not merely present.
      v6=$(getent ahostsv6 app.internal 2>/dev/null | awk 'NR==1{print $1}')
      if ! curl -s -m 5 -o /dev/null "http://[$v6]:8080/" 2>/dev/null; then
        echo "not yet: app.internal resolves to $v6 and nothing answers there."
        echo "         a AAAA record is a promise. Point it at an address this host"
        echo "         actually holds, or route the one it names."
        exit 1
      fi

      # 4. The measurement that started all this.
      out=$(/opt/client/fetch.py 2>&1 || true)
      secs=$(printf '%s' "$out" | sed -n 's/^elapsed=\([0-9.]*\).*/\1/p')
      if [ -z "$secs" ]; then
        echo "not yet: /opt/client/fetch.py did not report an elapsed time:"
        printf '%s\n' "$out" | sed 's/^/         /'
        exit 1
      fi
      if ! printf '%s' "$out" | grep -q 'dual-stack-2026'; then
        echo "not yet: the fetch no longer returns the page:"
        printf '%s\n' "$out" | sed 's/^/         /'
        exit 1
      fi
      slow=$(awk -v s="$secs" 'BEGIN { print (s >= 2.0) ? 1 : 0 }')
      if [ "$slow" = "1" ]; then
        echo "not yet: the fetch still takes ${secs}s."
        echo "         it is not the resolution and not the service. Time the connect"
        echo "         to each address the name returns, one at a time."
        exit 1
      fi

      echo "PASS — the fetch completes in ${secs}s over a working IPv6 path, with"
      echo "       the AAAA record intact and IPv6 still enabled."
