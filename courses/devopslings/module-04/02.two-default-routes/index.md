---
kind: lesson
title: "the box answers on one uplink and ignores the other"
description: |
  Two uplinks, both up, both addressed, both with a default route. Clients on
  one network are served and clients on the other time out — and the packets
  from the second network are arriving. It is the reply that never gets home.
name: two-default-routes
slug: two-default-routes
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

      systemctl stop box-web.service 2>/dev/null || true
      for ns in netA netB; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del up-a 2>/dev/null || true
      ip link del up-b 2>/dev/null || true
      ip route del 10.10.0.0/16 2>/dev/null || true
      ip route del 10.20.0.0/16 2>/dev/null || true

      # Two upstream networks, each a namespace standing in for a transit
      # provider. Each has a client address that is NOT on the link — reaching
      # it needs a routing decision, which is the point.
      #
      #   netA   gateway 192.168.10.1   client 10.10.0.10
      #   netB   gateway 192.168.20.1   client 10.20.0.20
      #
      # Neither gateway has a route to the other network's client. A reply that
      # leaves by the wrong uplink is dropped by the gateway that receives it,
      # silently, which is exactly what a transit provider does.
      mk_upstream() {
        ns=$1 veth=$2 gw=$3 client=$4
        ip netns add "$ns"
        ip link add "$veth" type veth peer name "up-in"
        ip link set up-in netns "$ns"
        ip netns exec "$ns" ip link set lo up
        ip netns exec "$ns" ip addr add "$gw/24" dev up-in
        ip netns exec "$ns" ip link set up-in up
        ip netns exec "$ns" ip link add dummy0 type dummy
        ip netns exec "$ns" ip addr add "$client/32" dev dummy0
        ip netns exec "$ns" ip link set dummy0 up
      }
      mk_upstream netA up-a 192.168.10.1 10.10.0.10
      mk_upstream netB up-b 192.168.20.1 10.20.0.20

      ip addr add 192.168.10.2/24 dev up-a && ip link set up-a up
      ip addr add 192.168.20.2/24 dev up-b && ip link set up-b up

      # eth0 is the management interface on this box and is not supposed to
      # carry traffic. It arrives with a default route at metric 0, which would
      # outrank both uplinks and make this a different lesson, so it goes. The
      # connected route to the lab network stays.
      ip route del default dev eth0 2>/dev/null || true

      # Both uplinks offer a default route. They cannot both be used: the
      # prefixes are identical, so the tie falls to the metric, and A wins.
      ip route add default via 192.168.10.1 dev up-a metric 100
      ip route add default via 192.168.20.1 dev up-b metric 200

      install -d /srv/box
      echo "box-answers-2026" > /srv/box/index.html
      cat > /etc/systemd/system/box-web.service <<'UNIT'
      [Unit]
      Description=the service both networks are supposed to reach
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/box
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now box-web.service >/dev/null 2>&1
      sleep 1

      cat > /root/questions.txt <<'Q'
      This box has two uplinks, up-a and up-b. Both are up, both are addressed,
      and the service on :8080 is bound to 0.0.0.0. (eth0 is management only —
      it has no default route and is not part of this.)

      A client on network A reaches it:

        ip netns exec netA curl --interface 10.10.0.10 http://192.168.10.2:8080/

      A client on network B does not:

        ip netns exec netB curl --interface 10.20.0.20 http://192.168.20.2:8080/

      Network B's request does arrive — you can watch it with tcpdump on up-b.
      Nothing is filtering. The service is listening on both addresses.

      Make network B's client reach the service, with the reply leaving by the
      uplink the request came in on. Leave both uplinks up and addressed, and
      do not break network A.

      The service serves a page containing box-answers-2026.
      Q

      echo "scenario ready — network A is served, network B times out"
      ip route show | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # 1. Both uplinks must still be up and addressed. Taking one down makes
      #    the ambiguity disappear and takes an upstream with it.
      for pair in "up-a 192.168.10.2" "up-b 192.168.20.2"; do
        dev=${pair% *}; addr=${pair#* }
        if ! ip -br addr show dev "$dev" 2>/dev/null | grep -q "$addr"; then
          echo "not yet: $dev is gone, down, or no longer holds $addr."
          echo "         removing an uplink does stop it being chosen wrongly. It also"
          echo "         stops it being an uplink."
          exit 1
        fi
      done

      # 2. The reply path for each client must leave by that client's own
      #    uplink. This is the actual fault, and it is asymmetric per network.
      sel_a=$(ip route get 10.10.0.10 2>&1)
      sel_b=$(ip route get 10.20.0.20 2>&1)

      if ! printf '%s' "$sel_a" | grep -q 'dev up-a'; then
        echo "not yet: replies to network A's client no longer leave by up-a:"
        printf '%s\n' "$sel_a" | sed 's/^/         /'
        exit 1
      fi

      if ! printf '%s' "$sel_b" | grep -q 'dev up-b'; then
        echo "not yet: replies to network B's client still leave by the wrong uplink:"
        printf '%s\n' "$sel_b" | sed 's/^/         /'
        echo "         B's request arrives on up-b. If the reply leaves on up-a it is"
        echo "         handed to a gateway with no route back to 10.20.0.20, which"
        echo "         drops it without telling anyone."
        exit 1
      fi

      # 3. It has to actually work, from both networks, end to end.
      a=$(ip netns exec netA curl -s -m 5 --interface 10.10.0.10 \
            http://192.168.10.2:8080/ 2>&1 || true)
      if ! printf '%s' "$a" | grep -q 'box-answers-2026'; then
        echo "not yet: network A's client can no longer reach the service."
        echo "         it worked before the change — whatever was done took A with it."
        exit 1
      fi

      b=$(ip netns exec netB curl -s -m 5 --interface 10.20.0.20 \
            http://192.168.20.2:8080/ 2>&1 || true)
      if ! printf '%s' "$b" | grep -q 'box-answers-2026'; then
        echo "not yet: network B's client still cannot reach the service."
        echo "         the route selection is right, so the request is arriving and"
        echo "         the reply is leaving by up-b. Check the service is still up:"
        echo "         systemctl status box-web.service"
        exit 1
      fi

      echo "PASS — both uplinks are up, each network's replies leave by the uplink"
      echo "       its requests arrive on, and both clients are served."
