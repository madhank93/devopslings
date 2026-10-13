---
kind: lesson
title: "the BGP session is up, and the internet still cannot find us"
description: |
  The new transit circuit is live. The BGP session to the provider came up on
  the first try and has stayed Established all morning. Nobody outside can reach
  the public block it was ordered for, and the provider says they are receiving
  nothing. The session is fine. What it carries is not.
name: bgp-session-up-no-routes
slug: bgp-session-up-no-routes
createdAt: "2026-10-13"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop frr.service 'frr@*.service' public-web.service 2>/dev/null || true
      systemctl reset-failed 'frr@*.service' frr.service public-web.service 2>/dev/null || true
      for l in to-isp svc0 corp0; do ip link del "$l" 2>/dev/null || true; done
      ip netns del isp 2>/dev/null || true
      ip route flush proto bgp 2>/dev/null || true
      ip route del 192.0.2.0/24 2>/dev/null || true
      rm -rf /etc/frr/isp /etc/systemd/system/frr@.service.d /srv/public
      rm -f /etc/systemd/system/public-web.service

      if [ ! -f /usr/share/frr-lesson-daemons ]; then
        sed -E 's/^(bgpd|ospfd)=yes/\1=no/' /etc/frr/daemons > /usr/share/frr-lesson-daemons
      fi

      # ---- the topology ------------------------------------------------
      #
      #   this box, AS 65010                         isp, AS 64500
      #   svc0  198.51.100.10/24  (our public block)
      #   corp0 10.82.0.1/24      (internal)
      #   to-isp 10.83.0.1/30  ───────────────────  cust0 10.83.0.2/30
      #                                             inet0 192.0.2.10/24
      #                                             (a user out on the internet)
      #
      # 198.51.100.0/24 and 192.0.2.0/24 are documentation ranges standing in
      # for real public space.
      ip link add svc0 type dummy
      ip addr add 198.51.100.10/24 dev svc0
      ip link set svc0 up
      ip link add corp0 type dummy
      ip addr add 10.82.0.1/24 dev corp0
      ip link set corp0 up

      ip netns add isp
      ip link add to-isp type veth peer name cust0 netns isp
      ip addr add 10.83.0.1/30 dev to-isp
      ip link set to-isp up
      ip netns exec isp sh -c '
        ip link set lo up
        ip addr add 10.83.0.2/30 dev cust0
        ip link set cust0 up
        ip link add inet0 type dummy
        ip addr add 192.0.2.10/24 dev inet0
        ip link set inet0 up
        sysctl -qw net.ipv4.ip_forward=1
      '

      # ---- the provider ------------------------------------------------
      #
      # Configured the way a transit provider configures a customer: accept
      # only the prefixes the customer registered, send them everything.
      install -d -o frr -g frr -m 755 /etc/frr/isp
      sed 's/^bgpd=no/bgpd=yes/' /usr/share/frr-lesson-daemons > /etc/frr/isp/daemons
      cp /etc/frr/vtysh.conf /etc/frr/isp/vtysh.conf
      cat > /etc/frr/isp/frr.conf <<'CONF'
      frr defaults traditional
      hostname isp
      log syslog informational
      !
      ip prefix-list CUSTOMER-65010 seq 5 permit 198.51.100.0/24
      !
      route-map TO-CUSTOMER permit 10
      !
      router bgp 64500
       bgp router-id 10.83.0.2
       neighbor 10.83.0.1 remote-as 65010
       neighbor 10.83.0.1 description customer-65010
       !
       address-family ipv4 unicast
        network 192.0.2.0/24
        neighbor 10.83.0.1 prefix-list CUSTOMER-65010 in
        neighbor 10.83.0.1 route-map TO-CUSTOMER out
       exit-address-family
      !
      CONF
      chown frr:frr /etc/frr/isp/*
      chmod 640 /etc/frr/isp/frr.conf

      install -d /etc/systemd/system/frr@.service.d
      printf '[Service]\nNetworkNamespacePath=/run/netns/%%i\n' > /etc/systemd/system/frr@.service.d/netns.conf

      # ---- this box ----------------------------------------------------
      sed 's/^bgpd=no/bgpd=yes/' /usr/share/frr-lesson-daemons > /etc/frr/daemons
      cat > /etc/frr/frr.conf <<'CONF'
      frr defaults traditional
      hostname edge
      log syslog informational
      !
      router bgp 65010
       bgp router-id 10.83.0.1
       neighbor 10.83.0.2 remote-as 64500
       neighbor 10.83.0.2 description transit-isp
       !
       address-family ipv4 unicast
        ! announce our block (svc0)
        redistribute connected
       exit-address-family
      !
      CONF
      chown frr:frr /etc/frr/daemons /etc/frr/frr.conf
      chmod 640 /etc/frr/frr.conf

      install -d /srv/public
      echo "public-block-answers-2026" > /srv/public/index.html
      printf '[Unit]\nDescription=the public service on 198.51.100.10\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/python3 -m http.server 8080 --bind 198.51.100.10 --directory /srv/public\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/public-web.service

      systemctl daemon-reload
      systemctl start frr@isp.service frr.service public-web.service

      for _ in $(seq 1 60); do
        vtysh -c 'show bgp ipv4 summary' 2>/dev/null | grep -q '^10\.83\.0\.2 .*(Policy)' && break
        sleep 1
      done

      cat > /root/questions.txt <<'Q'
      This box is our edge router, AS 65010. The new transit circuit to the
      provider (AS 64500) went live this morning:

        vtysh -c 'show bgp ipv4 summary'

      The session is up. It has been up for hours. The provider's NOC says
      they are receiving no routes from us, and nobody outside can reach our
      public block, 198.51.100.0/24. From a user on the internet (192.0.2.10,
      behind the provider):

        ip netns exec isp curl -s -m 5 --interface 192.0.2.10 http://198.51.100.10:8080/

      Make that work, through BGP in both directions: the provider must learn
      198.51.100.0/24 from us, and we must learn 192.0.2.0/24 from them. No
      static routes. The provider's router (vtysh -N isp) is theirs: read it,
      do not change it.

      We announce 198.51.100.0/24 to the provider and nothing else. Our other
      networks are internal.

      It must survive a restart of frr.service.
      Q

      echo "scenario ready — session Established, nothing exchanged"
      vtysh -c 'show bgp ipv4 summary' 2>/dev/null | sed -n '/^Neighbor/,$p' | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ISP=10.83.0.2

      # ---- the provider's router is not ours ---------------------------
      if ! grep -q '^ *neighbor 10.83.0.1 prefix-list CUSTOMER-65010 in' /etc/frr/isp/frr.conf 2>/dev/null \
         || ! vtysh -N isp -c 'show running-config' 2>/dev/null | grep -q 'neighbor 10.83.0.1 prefix-list CUSTOMER-65010 in'; then
        echo "not yet: the provider's inbound filter for us has been changed."
        echo "         That router belongs to AS 64500. Put it back; the fix is on"
        echo "         this side."
        exit 1
      fi
      if ip netns exec isp ip route show 198.51.100.0/24 2>/dev/null | grep -qv 'proto bgp'; then
        echo "not yet: the provider's namespace has a hand-made route to 198.51.100.0/24."
        echo "         The provider has to learn it from us, over BGP — that is the"
        echo "         only way the rest of the internet would."
        exit 1
      fi

      if ! systemctl is-active --quiet frr.service; then
        echo "not yet: frr.service is not running.  journalctl -u frr.service -n 30"
        exit 1
      fi

      # ---- the session --------------------------------------------------
      est=0
      for _ in $(seq 1 20); do
        if vtysh -c "show bgp ipv4 neighbors $ISP json" 2>/dev/null | grep -q '"bgpState":"Established"'; then
          est=1; break
        fi
        sleep 1
      done
      if [ "$est" -ne 1 ]; then
        echo "not yet: the BGP session to $ISP is not Established. It was when you"
        echo "         started.  vtysh -c 'show bgp ipv4 neighbors $ISP' | head -20"
        exit 1
      fi

      # ---- what we send ------------------------------------------------
      #
      # The routes we hand the provider, after our own outbound policy. The
      # provider's filter happens to drop anything extra today; ours is the
      # one that is supposed to.
      adv=""
      for _ in $(seq 1 15); do
        adv=$(vtysh -c "show bgp ipv4 neighbors $ISP advertised-routes json" 2>/dev/null \
                | python3 -c 'import json,sys
      try: d=json.load(sys.stdin)
      except Exception: sys.exit(0)
      print(" ".join(sorted(d.get("advertisedRoutes", {}).keys())))' 2>/dev/null || true)
        [ -n "$adv" ] && break
        sleep 1
      done

      if [ -z "$adv" ]; then
        echo "not yet: this box advertises nothing to $ISP."
        echo "         The session is up and it is carrying no routes. Look at the"
        echo "         last two columns:"
        echo "           vtysh -c 'show bgp ipv4 summary'"
        echo "         and ask why a route this box clearly has is not being offered."
        exit 1
      fi
      if [ "$adv" != "198.51.100.0/24" ]; then
        echo "not yet: this box is advertising more than our public block to $ISP:"
        for p in $adv; do echo "           $p"; done
        echo "         The provider's filter is dropping the extras today. A provider"
        echo "         that does not filter passes them to the whole internet — that"
        echo "         is a route leak, and it is the default this box was protecting"
        echo "         you from. Announce 198.51.100.0/24 and nothing else."
        exit 1
      fi

      # ---- what we hear ------------------------------------------------
      r=""
      for _ in $(seq 1 15); do
        r=$(ip route show 192.0.2.0/24 2>/dev/null)
        printf '%s' "$r" | grep -q 'proto bgp' && break
        sleep 1
      done
      if ! printf '%s' "$r" | grep -q 'proto bgp'; then
        if [ -n "$r" ]; then
          echo "not yet: 192.0.2.0/24 is in the table and BGP did not put it there:"
          echo "           $r"
          echo "         A static route back to one prefix is not a transit circuit."
        else
          echo "not yet: the provider is announcing 192.0.2.0/24 and this box has not"
          echo "         accepted it. The rule that stops this box sending also stops it"
          echo "         receiving:"
          echo "           vtysh -c 'show bgp ipv4 neighbors $ISP received-routes'"
          echo "           vtysh -c 'show bgp ipv4 summary'"
        fi
        exit 1
      fi

      # ---- end to end --------------------------------------------------
      page=$(ip netns exec isp curl -s -m 5 --interface 192.0.2.10 http://198.51.100.10:8080/ 2>/dev/null || true)
      if ! printf '%s' "$page" | grep -q public-block-answers-2026; then
        echo "not yet: the routes are exchanged and a user at 192.0.2.10 still cannot"
        echo "         fetch http://198.51.100.10:8080/.  systemctl status public-web.service"
        exit 1
      fi

      # ---- and it survives a restart -----------------------------------
      saved=$(cat /etc/frr/frr.conf 2>/dev/null || true)
      if printf '%s\n' "$saved" | grep -Eq '^[[:space:]]*no bgp ebgp-requires-policy'; then
        echo "not yet: /etc/frr/frr.conf turns off ebgp-requires-policy."
        echo "         Whatever is filtering now, the saved config says this box may"
        echo "         exchange routes with an external peer with no policy at all."
        exit 1
      fi
      if ! printf '%s\n' "$saved" | grep -Eq "^[[:space:]]*neighbor $ISP (route-map|prefix-list|filter-list|distribute-list) [^ ]+ out"; then
        echo "not yet: it works, and /etc/frr/frr.conf has no outbound policy for $ISP."
        echo "         frr.service loads that file on restart. A change made in vtysh"
        echo "         lives in the running daemon until it is written out."
        exit 1
      fi
      if ! printf '%s\n' "$saved" | grep -Eq "^[[:space:]]*neighbor $ISP (route-map|prefix-list|filter-list|distribute-list) [^ ]+ in"; then
        echo "not yet: it works, and /etc/frr/frr.conf has no inbound policy for $ISP."
        echo "         frr.service loads that file on restart."
        exit 1
      fi

      echo "PASS — the session carries 198.51.100.0/24 out and 192.0.2.0/24 in, nothing"
      echo "       else leaves, and the policy is in the config frr.service will load."
