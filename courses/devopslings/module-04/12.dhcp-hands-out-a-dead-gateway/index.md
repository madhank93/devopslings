---
kind: lesson
title: "the new server got an address and cannot reach anything past its own subnet"
description: |
  A freshly provisioned server boots, asks for an address, and gets one. It can
  ping its neighbours. It cannot reach anything one hop further away. The DHCP
  server's config names the right gateway, in black and white — and the server
  is handing out a different one.
name: dhcp-hands-out-a-dead-gateway
slug: dhcp-hands-out-a-dead-gateway
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
      systemctl stop web3-dhcp.service lan-dhcp.service 2>/dev/null || true
      systemctl reset-failed web3-dhcp.service lan-dhcp.service 2>/dev/null || true
      for l in lan2-w3 lan2-pr lan2; do ip link del "$l" 2>/dev/null || true; done
      for ns in web3 dhcp-probe; do ip netns del "$ns" 2>/dev/null || true; done
      nft delete table ip lan2nat 2>/dev/null || true
      rm -rf /etc/lan-dhcp /var/lib/lan-dhcp
      rm -f /etc/systemd/system/lan-dhcp.service /etc/systemd/system/web3-dhcp.service
      install -d /etc/lan-dhcp/conf.d /var/lib/lan-dhcp

      # ---- the segment -------------------------------------------------
      #
      #   web3 (DHCP client) ── lan2 10.60.0.1 (this box: router + DHCP server)
      #                                │
      #                              eth0 172.31.0.10 ── peer 172.31.0.11
      #
      # 10.60.0.254 used to be the segment's gateway, a core switch that has
      # since been decommissioned. Nothing answers on it any more.
      # A bridge without a set MAC takes its lowest port's, so the grader's
      # probe port joining could change the gateway's MAC under web3.
      ip link add lan2 address 02:00:00:60:00:01 type bridge
      ip addr add 10.60.0.1/24 dev lan2
      ip link set lan2 up

      ip netns add web3
      ip link add lan2-w3 type veth peer name eth0 netns web3
      ip link set lan2-w3 master lan2 up
      ip netns exec web3 ip link set lo up
      ip netns exec web3 ip link set eth0 up

      # peer has no route back to 10.60.0.0/24, so the segment leaves through
      # this box's own address, as it would through any edge router.
      nft -f - <<'NFT'
      table ip lan2nat {
        chain post {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.60.0.0/24 oifname "eth0" masquerade
        }
      }
      NFT

      # ---- the DHCP server ---------------------------------------------
      cat > /etc/lan-dhcp/dnsmasq.conf <<'CONF'
      # DHCP for lan2. DNS is off: this instance only hands out leases.
      port=0
      interface=lan2
      bind-interfaces
      dhcp-authoritative
      dhcp-leasefile=/var/lib/lan-dhcp/leases
      conf-dir=/etc/lan-dhcp/conf.d,*.conf
      CONF

      cat > /etc/lan-dhcp/conf.d/10-lan2.conf <<'CONF'
      # lan2 — 10.60.0.0/24. Gateway is this box.
      dhcp-range=10.60.0.100,10.60.0.199,255.255.255.0,12h
      dhcp-option=option:router,10.60.0.1
      CONF

      # The fault. Left over from before the core switch was retired; read
      # after 10-lan2.conf, and dnsmasq keeps the last value it reads.
      cat > /etc/lan-dhcp/conf.d/50-core-migration.conf <<'CONF'
      # CHG-0412: lan2 default gateway moves to the core switch pair (VRRP .254)
      # Remove once the migration window closes.
      dhcp-option=3,10.60.0.254
      CONF

      printf '[Unit]\nDescription=DHCP server for lan2\nAfter=network.target\n\n[Service]\nExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/lan-dhcp/dnsmasq.conf\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/lan-dhcp.service

      # ---- the client --------------------------------------------------
      # dhcpcd in the background, holding and renewing its lease like any
      # server's network stack does. -A skips the duplicate-address probe,
      # which only adds five seconds.
      printf '[Unit]\nDescription=DHCP client for web3\nAfter=lan-dhcp.service\n\n[Service]\nNetworkNamespacePath=/run/netns/web3\nExecStart=/usr/sbin/dhcpcd -4 -B -A -C resolv.conf eth0\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/web3-dhcp.service

      systemctl daemon-reload
      systemctl enable --now lan-dhcp.service >/dev/null 2>&1
      systemctl enable --now web3-dhcp.service >/dev/null 2>&1

      for _ in $(seq 1 40); do
        ip netns exec web3 ip route show default 2>/dev/null | grep -q 'proto dhcp' && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      web3 was provisioned this morning on lan2 (10.60.0.0/24). It booted, ran
      DHCP, and got an address:

        ip netns exec web3 ip -br addr show eth0

      It can reach this box, which is its router:

        ip netns exec web3 ping -c2 10.60.0.1

      It cannot reach anything further away:

        ip netns exec web3 ping -c2 -W2 172.31.0.11

      This box runs the DHCP server for lan2 (lan-dhcp.service). Its config
      gives the router as 10.60.0.1. Forwarding and NAT for lan2 are working.

      Make web3 reach 172.31.0.11, and make sure the next server provisioned on
      lan2 does too.

      10.60.0.254 was the old core switch. It has been decommissioned, and the
      address is reserved for its replacement: do not bring it back here.
      Q

      echo "scenario ready — web3 has a lease and no way off its subnet"
      ip netns exec web3 ip route | sed 's/^/  web3: /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      OLD_GW=10.60.0.254

      if ip -4 -o addr show 2>/dev/null | grep -q " $OLD_GW/"; then
        echo "not yet: this box now holds $OLD_GW."
        echo "         That makes the bad lease work by giving it a gateway to find, and"
        echo "         the address is reserved for the core switch's replacement. When"
        echo "         that arrives you have a duplicate address on lan2. The lease is"
        echo "         what is wrong."
        exit 1
      fi

      if ! systemctl is-active --quiet lan-dhcp.service; then
        echo "not yet: lan-dhcp.service is not running. Nothing on lan2 can get or"
        echo "         renew a lease. systemctl status lan-dhcp.service"
        exit 1
      fi

      # ---- what a new server would be offered --------------------------
      #
      # A throwaway client asks for an offer and stops there (-T), so it takes
      # no lease and changes nothing. Its own interface name keeps it off
      # web3's dhcpcd control socket.
      ip link del lan2-pr 2>/dev/null || true
      ip netns del dhcp-probe 2>/dev/null || true
      ip netns add dhcp-probe
      ip link add lan2-pr type veth peer name probe0 netns dhcp-probe
      ip link set lan2-pr master lan2 up
      ip netns exec dhcp-probe ip link set probe0 up
      offer=$(ip netns exec dhcp-probe timeout 20 dhcpcd -4 -T -A -C resolv.conf probe0 2>/dev/null || true)
      ip link del lan2-pr 2>/dev/null || true
      ip netns del dhcp-probe 2>/dev/null || true

      routers=$(printf '%s\n' "$offer" | sed -n "s/^new_routers='\(.*\)'$/\1/p" | head -1)
      if [ -z "$routers" ]; then
        echo "not yet: a new client on lan2 got no DHCP offer at all within 20 seconds."
        echo "         Check the server is up and still listening on lan2:"
        echo "           journalctl -u lan-dhcp.service -n 20"
        exit 1
      fi
      if [ "$routers" != "10.60.0.1" ]; then
        echo "not yet: a new server on lan2 is still offered router $routers."
        if grep -rqs "$OLD_GW" /etc/lan-dhcp; then
          echo "         Read every file the server reads, not just the one that looks"
          echo "         like it is about lan2. When an option is set twice, which one"
          echo "         does dnsmasq keep?"
        else
          echo "         The config no longer says $OLD_GW. dnsmasq reads it once, at"
          echo "         start; the running process is still serving the old one."
        fi
        exit 1
      fi

      # ---- what web3 actually has --------------------------------------
      gw=$(ip netns exec web3 ip route show default 2>/dev/null | head -1)
      if ! printf '%s' "$gw" | grep -q 'via 10.60.0.1 '; then
        echo "not yet: the server now offers the right router, and web3 still has:"
        echo "           ${gw:-no default route}"
        echo "         A client keeps the options it was given until it renews, and this"
        echo "         lease is good for 12 hours. Ask web3's DHCP client to renew."
        exit 1
      fi
      if ! printf '%s' "$gw" | grep -q 'proto dhcp'; then
        echo "not yet: web3's default route points at 10.60.0.1, and it was not put"
        echo "         there by DHCP:"
        echo "           $gw"
        echo "         A hand-set route on the client is a fix for this one server, and"
        echo "         the next server provisioned on lan2 gets the same broken lease."
        exit 1
      fi
      if ip netns exec web3 ip route show default 2>/dev/null | grep -q "$OLD_GW"; then
        echo "not yet: web3 still has a default route via $OLD_GW alongside the good one."
        exit 1
      fi

      # A renew that has just landed can still be settling ARP for the new
      # gateway, so give it a few tries.
      reached=0
      for _ in 1 2 3 4 5; do
        if ip netns exec web3 ping -c1 -W2 172.31.0.11 >/dev/null 2>&1; then
          reached=1; break
        fi
      done
      if [ "$reached" -ne 1 ]; then
        echo "not yet: web3 has the right gateway from DHCP and still cannot reach"
        echo "         172.31.0.11. Forwarding and NAT worked before you started; check"
        echo "         neither was changed:  sysctl net.ipv4.ip_forward ; nft list table ip lan2nat"
        exit 1
      fi

      echo "PASS — the DHCP server offers 10.60.0.1, web3 holds a lease that says so, and"
      echo "       web3 reaches past its own subnet."
