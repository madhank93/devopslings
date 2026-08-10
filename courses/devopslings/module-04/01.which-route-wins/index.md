---
kind: lesson
title: "three routes match, and the one you read first is not the one that wins"
description: |
  The partner network is reachable. The route is in the table — somebody can
  point at it. One host inside that network answers and another one does not,
  and the difference is a route nobody scrolled far enough to see.
name: which-route-wins
slug: which-route-wins
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

      # ---- clean slate -------------------------------------------------
      systemctl stop partner-web.service 2>/dev/null || true
      ip netns del partner 2>/dev/null || true
      ip link del to-partner 2>/dev/null || true
      ip route del 10.50.7.0/24 2>/dev/null || true
      ip route del 10.50.0.0/16 2>/dev/null || true

      # ---- the "partner network", built in a namespace -----------------
      # It lives in a netns rather than on the peer box so the lesson is about
      # route selection and nothing else. Two addresses, one host: 10.50.1.5
      # will turn out to work and 10.50.7.5 will not.
      install -d /srv/partner
      echo "partner-net-2026" > /srv/partner/index.html

      ip netns add partner
      ip link add to-partner type veth peer name to-box
      ip link set to-box netns partner

      ip addr add 10.60.0.1/30 dev to-partner
      ip link set to-partner up

      ip netns exec partner ip link set lo up
      ip netns exec partner ip addr add 10.60.0.2/30 dev to-box
      ip netns exec partner ip link set to-box up
      ip netns exec partner ip link add dummy0 type dummy
      ip netns exec partner ip addr add 10.50.1.5/32 dev dummy0
      ip netns exec partner ip addr add 10.50.7.5/32 dev dummy0
      ip netns exec partner ip link set dummy0 up
      ip netns exec partner ip route add default via 10.60.0.1

      # A real unit, in the namespace, so `systemctl status` tells the truth
      # about it. Binding 0.0.0.0 inside the namespace serves both addresses.
      cat > /etc/systemd/system/partner-web.service <<'UNIT'
      [Unit]
      Description=partner network web host
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/partner
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/partner
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now partner-web.service >/dev/null 2>&1

      # ---- the routing table the student inherits ----------------------
      # Correct, and it is the one everybody points at when asked.
      ip route add 10.50.0.0/16 via 10.60.0.2 dev to-partner

      # Left behind when the old partner gateway was decommissioned. It is more
      # specific than the /16, so it wins for anything in 10.50.7.0/24, and
      # 172.31.0.99 has not answered ARP for months.
      ip route add 10.50.7.0/24 via 172.31.0.99 dev eth0

      cat > /root/questions.txt <<'Q'
      The partner network is 10.50.0.0/16, reached through this box.

        curl http://10.50.1.5:8080/   works
        curl http://10.50.7.5:8080/   hangs until it times out

      Both addresses are the same host on the far side. The route for the
      partner network is in the table and it is correct.

      Make 10.50.7.5 reachable, without breaking 10.50.1.5 and without
      removing the 10.50.0.0/16 route or the default route.

      The far side serves a file containing the word partner-net-2026.
      Q

      echo "scenario ready — 10.50.1.5 answers, 10.50.7.5 does not"
      ip route show | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # 1. The default route. Deleting it makes the specific-route problem go
      #    away and takes the box off the network, so it is checked first.
      if ! ip route show default | grep -q .; then
        echo "not yet: there is no default route any more."
        echo "         removing it does stop the wrong route being chosen, because"
        echo "         nothing is chosen at all. The box is now off the network."
        exit 1
      fi

      # 2. The /16 was the one route in the table that was already correct.
      if ! ip route show 10.50.0.0/16 | grep -q '10.60.0.2'; then
        echo "not yet: the 10.50.0.0/16 route is gone or no longer points at 10.60.0.2."
        echo "         it was the route that was right to begin with — the fault was"
        echo "         never in it."
        exit 1
      fi

      # 3. Which route the kernel actually selects. This is the whole lesson:
      #    'ip route show' lists what is configured, 'ip route get' answers what
      #    wins.
      sel=$(ip route get 10.50.7.5 2>&1)
      if printf '%s' "$sel" | grep -q '172.31.0.99'; then
        echo "not yet: the kernel still selects the decommissioned gateway."
        printf '%s\n' "$sel" | sed 's/^/         /'
        echo "         'ip route show' lists routes. 'ip route get' is the one that"
        echo "         says which of them wins for a given address."
        exit 1
      fi

      # 4. It has to actually work, not merely resolve to a different nexthop.
      body=$(curl -s -m 5 http://10.50.7.5:8080/ 2>&1 || true)
      if ! printf '%s' "$body" | grep -q 'partner-net-2026'; then
        echo "not yet: 10.50.7.5 still does not serve the page."
        echo "         the kernel now selects:"
        printf '%s\n' "$sel" | sed 's/^/         /'
        exit 1
      fi

      # 5. And the address that already worked must still work — a fix that
      #    trades one half of the partner network for the other is not a fix.
      body=$(curl -s -m 5 http://10.50.1.5:8080/ 2>&1 || true)
      if ! printf '%s' "$body" | grep -q 'partner-net-2026'; then
        echo "not yet: 10.50.1.5 answered at the start and does not any more."
        echo "         whatever was changed took the rest of the partner network"
        echo "         down with it."
        exit 1
      fi

      echo "PASS — 10.50.7.5 is reachable, the /16 and the default route are intact,"
      echo "       and the kernel now selects the partner path for the whole network."
