---
kind: lesson
title: "the address moved an hour ago, and this box is still knocking on the old door"
description: |
  A floating IP failed over from one app server to the other. The new holder
  answers on it, every other host on the segment reaches it, and this box times
  out. The route is right and nothing filters. What is wrong is the one table
  nobody reads: the box knows which MAC address the IP lives at, and it is sure.
name: stale-arp-after-failover
slug: stale-arp-after-failover
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

      # ---- clean slate -------------------------------------------------
      systemctl stop vip-web.service pin-neighbours.service 2>/dev/null || true
      systemctl disable pin-neighbours.service 2>/dev/null || true
      # Host-side veths first: a deleted namespace frees its end asynchronously,
      # and re-creating the pair races that.
      for l in lan1-a lan1-b lan1; do ip link del "$l" 2>/dev/null || true; done
      for ns in app-a app-b; do ip netns del "$ns" 2>/dev/null || true; done
      rm -f /etc/neighbours.conf /etc/systemd/system/pin-neighbours.service \
            /etc/systemd/system/vip-web.service
      install -d /srv/vip

      # ---- the segment -------------------------------------------------
      #
      #   app-a 10.70.0.11  02:00:00:70:00:0a ─┐
      #                                        ├─ lan1 10.70.0.1 (this box)
      #   app-b 10.70.0.12  02:00:00:70:00:0b ─┘
      #         10.70.0.100 (the VIP, since the failover)
      #
      # lan1 is a Linux bridge, which is a switch: it learns which port each
      # MAC sits behind and forwards frames by MAC alone. The MACs are pinned so
      # the lesson text can name them.
      ip link add lan1 type bridge
      ip addr add 10.70.0.1/24 dev lan1
      ip link set lan1 up

      mk_host() {
        ns=$1 port=$2 addr=$3 mac=$4
        ip netns add "$ns"
        ip link add "$port" type veth peer name eth0 netns "$ns"
        ip link set "$port" master lan1 up
        ip netns exec "$ns" ip link set lo up
        ip netns exec "$ns" ip link set eth0 address "$mac"
        ip netns exec "$ns" ip addr add "$addr/24" dev eth0
        ip netns exec "$ns" ip link set eth0 up
        # A new namespace inherits this box's forwarding=1. A server that
        # routes would relay the misaddressed frames and hide the fault.
        ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=0
      }
      mk_host app-a lan1-a 10.70.0.11 02:00:00:70:00:0a
      mk_host app-b lan1-b 10.70.0.12 02:00:00:70:00:0b

      # The VIP lives on app-b now. app-a has been drained: it is up, it still
      # answers on its own address, and a frame sent to its MAC for an IP it
      # does not hold is discarded without a word.
      ip netns exec app-b ip addr add 10.70.0.100/24 dev eth0

      echo "vip-answers-2026" > /srv/vip/index.html
      printf '[Unit]\nDescription=the service behind the floating IP\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/app-b\nExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/vip\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/vip-web.service

      # ---- the pin -----------------------------------------------------
      #
      # The fault. Someone fixed an ARP storm once by telling this box where the
      # VIP lives, permanently, and made it come back on every boot.
      cat > /etc/neighbours.conf <<'CONF'
      # Static neighbour entries, applied at boot by pin-neighbours.service.
      #
      # INC-2231 (March): the VIP flapped between app-a and app-b during the
      # keepalived split-brain and every client saw its ARP entry change twice a
      # second. Pinned to the primary until the cluster is fixed.
      #
      # <ip>          <mac>               <dev>
      10.70.0.100     02:00:00:70:00:0a   lan1
      CONF

      cat > /usr/local/sbin/pin-neighbours <<'SH'
      #!/bin/sh
      # Apply /etc/neighbours.conf as permanent entries in the neighbour table.
      grep -Ev '^[[:space:]]*(#|$)' /etc/neighbours.conf | while read -r ip mac dev; do
        ip neigh replace "$ip" lladdr "$mac" dev "$dev" nud permanent
      done
      SH
      chmod 755 /usr/local/sbin/pin-neighbours

      printf '[Unit]\nDescription=pin static neighbour entries from /etc/neighbours.conf\nAfter=network.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/sbin/pin-neighbours\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/pin-neighbours.service

      systemctl daemon-reload
      systemctl enable --now vip-web.service >/dev/null 2>&1
      systemctl enable --now pin-neighbours.service >/dev/null 2>&1

      for _ in $(seq 1 20); do
        ip netns exec app-b curl -s -m 1 http://10.70.0.100:8080/ 2>/dev/null \
          | grep -q vip-answers-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The floating IP 10.70.0.100 failed over from app-a to app-b an hour ago.
      Planned, clean, and app-b holds it:

        ip netns exec app-b ip -br addr show eth0
        ip netns exec app-b curl -s http://10.70.0.100:8080/

      From this box, which sits on the same segment (lan1, 10.70.0.1):

        curl -s -m 5 http://10.70.0.100:8080/       # times out
        curl -s -m 5 http://10.70.0.12:8080/        # app-b's own address: works

      Same host, same port, same subnet, no firewall. One address works and
      the other does not.

      Make this box reach the service on 10.70.0.100 again, in a way that
      survives the next failover and the next boot.

      app-a has been drained and stays that way: the VIP does not go back to it.
      The service serves a page containing vip-answers-2026.
      Q

      echo "scenario ready — app-b holds the VIP, this box cannot reach it"
      ip neigh show dev lan1 | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      VIP=10.70.0.100
      MAC_A=02:00:00:70:00:0a

      # ---- the failover stands ----------------------------------------
      if ip netns exec app-a ip -4 -o addr show 2>/dev/null | grep -q " $VIP/"; then
        echo "not yet: app-a holds $VIP again."
        echo "         That makes the stale entry true instead of fixing it. app-a was"
        echo "         drained for a reason, and the next failover will strand you"
        echo "         exactly the same way."
        exit 1
      fi
      if ! ip netns exec app-b ip -4 -o addr show 2>/dev/null | grep -q " $VIP/"; then
        echo "not yet: app-b no longer holds $VIP. The failover is not yours to undo;"
        echo "         put the address back on app-b's eth0."
        exit 1
      fi

      # ---- it answers from here ---------------------------------------
      page=$(curl -s -m 5 "http://$VIP:8080/" 2>/dev/null || true)
      if ! printf '%s' "$page" | grep -q vip-answers-2026; then
        echo "not yet: this box still cannot reach the service on $VIP:8080."
        entry=$(ip neigh show "$VIP" 2>/dev/null)
        if printf '%s' "$entry" | grep -qi "$MAC_A"; then
          echo "         This box is addressing $VIP's frames to $MAC_A:"
          echo "           $entry"
          echo "         Find out whose MAC that is."
        else
          echo "         Start where the packet leaves: what does this box believe about"
          echo "         $VIP at layer 2?  ip neigh show $VIP"
        fi
        exit 1
      fi

      # ---- and it is reaching it the ordinary way ----------------------
      entry=$(ip neigh show "$VIP" dev lan1 2>/dev/null)
      if printf '%s' "$entry" | grep -q PERMANENT; then
        echo "not yet: $VIP still has a PERMANENT entry in the neighbour table:"
        echo "           $entry"
        if printf '%s' "$entry" | grep -qi "$MAC_A"; then
          echo "         It is pinned to app-a and traffic is going around it. The pin is"
          echo "         still wrong, and anything that takes the plain path hits it."
        else
          echo "         It points at the right host today. A floating IP is one that moves;"
          echo "         pinning it to app-b reproduces this outage at the next failover,"
          echo "         in the other direction."
        fi
        exit 1
      fi

      # ---- and it stays fixed after a boot ----------------------------
      if systemctl is-enabled pin-neighbours.service >/dev/null 2>&1 \
         && grep -Ev '^[[:space:]]*#' /etc/neighbours.conf 2>/dev/null | grep -q "^[[:space:]]*$VIP[[:space:]]"; then
        echo "not yet: the neighbour table is clean now, and /etc/neighbours.conf still"
        echo "         pins $VIP for pin-neighbours.service to apply at the next boot."
        echo "         The entry you deleted was put there by that file; it will be back."
        exit 1
      fi

      echo "PASS — $VIP is reached by its current MAC, learned by ARP rather than pinned,"
      echo "       and nothing will put the stale pin back at boot."
