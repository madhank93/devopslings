---
kind: lesson
title: "the service is up, the port is open, and the connection is refused"
description: |
  It answers instantly on the box it runs on. From anywhere else it is refused
  before a packet of the request is written. The firewall is the first thing
  everyone checks, and the firewall is not doing anything.
name: bound-to-the-wrong-interface
slug: bound-to-the-wrong-interface
createdAt: "2026-08-10"

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
      systemctl stop svc-orders.service 2>/dev/null || true
      ip netns del outside 2>/dev/null || true
      ip link del to-outside 2>/dev/null || true
      nft delete table inet edge 2>/dev/null || true
      install -d /opt/orders

      # ---- the "outside" network -------------------------------------
      ip netns add outside
      ip link add to-outside type veth peer name out0
      ip link set out0 netns outside
      ip addr add 203.0.113.1/30 dev to-outside
      ip link set to-outside up
      ip netns exec outside ip link set lo up
      ip netns exec outside ip addr add 203.0.113.2/30 dev out0
      ip netns exec outside ip link set out0 up
      ip netns exec outside ip route add default via 203.0.113.1

      # orders answers. It serves a known string.
      cat > /opt/orders/index.html <<'HTML'
      orders-canonical-2026
      HTML
      chmod 644 /opt/orders/index.html

      # ---- the misbound service -------------------------------------
      cat > /etc/systemd/system/svc-orders.service <<'UNIT'
      [Unit]
      Description=orders API
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory /opt/orders
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now svc-orders.service >/dev/null 2>&1

      # ---- the decoy firewall -----------------------------------------
      # A ruleset that exists, is visible, and blocks nothing — because the
      # ticket blames it.
      nft add table inet edge
      nft 'add chain inet edge input { type filter hook input priority 0 ; policy accept ; }'
      nft add rule inet edge input tcp dport 8080 accept
      nft add rule inet edge input ct state established,related accept

      # Wait for the service to actually be answering before handing the box
      # over, so the first thing the student runs is not a false negative.
      for _ in $(seq 1 20); do
        curl -s -m 1 http://127.0.0.1:8080/ 2>/dev/null | grep -q orders-canonical-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The orders API answers on this box and is refused from every other machine.
      curl http://127.0.0.1:8080/ returns the page. From the peer box, and from
      203.0.113.2, the same request is refused instantly.

      The firewall was the first suspect and it accepts port 8080 — nft list ruleset
      is there to read.

      Make the service answer on 172.31.0.10, the box's address on the lab network,
      while still refusing on 203.0.113.1, the box's address on the outside network.

      Binding to every interface is not the fix, and the check will reject it.

      Constraints:
        - leave the nftables ruleset alone
        - do not put anything in front of the service — no socat, no port forwarding,
          no redirect. The listening socket itself must move.
      Q

      echo "scenario ready — answers on loopback, refused everywhere else"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # Check that the service is still running
      if ! systemctl is-active --quiet svc-orders.service; then
        echo "not yet: svc-orders.service is not running."
        echo "         it was running when you started, and a stopped service is"
        echo "         refused from everywhere including this box."
        exit 1
      fi

      # Collect the listening addresses once, guarded so a failure cannot end
      # the script
      listeners=$(ss -ltnH 'sport = :8080' 2>/dev/null | awk '{print $4}' || true)

      if [ -z "$listeners" ]; then
        echo "not yet: nothing is listening on 8080 any more."
        exit 1
      fi

      # Check that the service is not bound to all interfaces
      if printf '%s\n' "$listeners" | grep -qE '^(0\.0\.0\.0|\[::\]):8080$'; then
        echo "not yet: the service is bound to every interface on the box."
        echo "         that does make it reachable from the lab network, and it also"
        echo "         puts it on 203.0.113.1, where it must never appear. Bind it to"
        echo "         one address, not all of them."
        exit 1
      fi

      # Check that the service is not still bound to loopback
      if printf '%s\n' "$listeners" | grep -qE '^127\.0\.0\.1:8080$' && [ "$(printf '%s\n' "$listeners" | wc -l)" = 1 ]; then
        echo "not yet: the only listener is still 127.0.0.1:8080."
        echo "         that address means \"this machine and nothing else\". No firewall"
        echo "         rule and no route can make a socket bound to it answer another"
        echo "         machine."
        exit 1
      fi

      # Check that the service is not listening on the outside address
      if printf '%s\n' "$listeners" | grep -q '^203\.0\.113\.1:8080$'; then
        echo "not yet: the service is listening on 203.0.113.1, the outside address."
        echo "         that is the one place it must never be."
        exit 1
      fi

      # Check that the service is listening on the lab address
      if ! printf '%s\n' "$listeners" | grep -q '^172\.31\.0\.10:8080$'; then
        echo "not yet: nothing is listening on 172.31.0.10:8080, the box's address on"
        echo "         the lab network. Current listeners:"
        printf '%s\n' "$listeners" | sed 's/^/           /'
        exit 1
      fi

      # The listener on the lab address has to be the service itself. A socat
      # relay or a port forward in front of an unchanged 127.0.0.1 socket also
      # answers on this address, and leaves the actual fault in place.
      owner=$(ss -ltnpH 'sport = :8080' 2>/dev/null | grep '172\.31\.0\.10:8080' | head -1 || true)
      if ! printf '%s' "$owner" | grep -q 'python3'; then
        echo "not yet: the listener on 172.31.0.10:8080 is not the orders service."
        printf '%s\n' "$owner" | sed 's/^/           /'
        echo "         something has been put in front of it. The service's own socket"
        echo "         is what has to move — a relay leaves the original binding exactly"
        echo "         as wrong as it was, one process further back."
        exit 1
      fi

      # Check that the page is actually served
      body=$(curl -s -m 5 http://172.31.0.10:8080/ 2>&1 || true)
      if ! echo "$body" | grep -q 'orders-canonical-2026'; then
        echo "not yet: the socket is bound correctly but the page did not come back."
        exit 1
      fi

      # Check that the service is refused on the outside
      outside=$(ip netns exec outside curl -s -m 5 -o /dev/null -w '%{http_code}' http://203.0.113.1:8080/ 2>/dev/null || true)
      if [ "$outside" = "200" ]; then
        echo "not yet: the outside network can reach the service on 203.0.113.1."
        echo "         the lab network is the only place this belongs."
        exit 1
      fi

      echo "PASS — the orders API listens on 172.31.0.10:8080 and serves the page,"
      echo "       and 203.0.113.1 still refuses it."
