---
kind: lesson
title: "build a container's network by hand, then name what Docker was doing"
description: |
  Two namespaces with nothing but a loopback interface. By the end they talk to
  each other, to this box, and to the world — over a bridge and two veth pairs
  you made yourself. Every piece has a name, and every name turns up again in
  `docker network inspect`.
name: netns-veth-bridge
slug: netns-veth-bridge
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

      systemctl stop lab-web.service 2>/dev/null || true
      for ns in app1 app2; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del br0 2>/dev/null || true
      for l in veth-app1 veth-app2; do ip link del "$l" 2>/dev/null || true; done
      nft delete table ip lab-nat 2>/dev/null || true

      # Two namespaces with a loopback and nothing else. This is what a
      # container gets before anything wires it up.
      for ns in app1 app2; do
        ip netns add "$ns"
        ip netns exec "$ns" ip link set lo up
      done

      install -d /srv/lab
      echo "lab-net-2026" > /srv/lab/index.html
      cat > /etc/systemd/system/lab-web.service <<'UNIT'
      [Unit]
      Description=a service on the box, for the namespaces to reach
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/lab
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now lab-web.service >/dev/null 2>&1

      # Forwarding is off. A box that will not forward cannot be a router, and
      # the namespaces need one.
      sysctl -w net.ipv4.ip_forward=0 >/dev/null

      cat > /root/questions.txt <<'Q'
      There are two network namespaces, app1 and app2. Each has a loopback
      interface and nothing else. That is exactly what a container starts with.

      Wire them up, by hand, so that all three of these work:

        1. app1 can ping app2
        2. app1 can fetch http://172.31.0.10:8080/ from this box
        3. app1 can ping 172.31.0.11, the peer box on the lab network

      Use the subnet 10.77.0.0/24, with the bridge holding 10.77.0.1.

      Requirement: the two namespaces must be joined by a bridge named br0 with
      a veth pair each. Handing them a route to the outside without a bridge
      solves numbers 2 and 3 and is not what is being asked — the point is the
      shape, because it is the shape Docker builds.

      Number 3 is the one that needs more than addressing. The peer box has
      never heard of 10.77.0.0/24 and will not route a reply to it.

      Tools: ip link, ip addr, ip route, ip netns exec, sysctl, nft.
      Q

      echo "scenario ready — app1 and app2 exist and have only lo"
      ip netns list | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # 1. The shape. A route handed straight to the namespaces would pass the
      #    connectivity checks, so the structure is checked on its own.
      if ! ip link show br0 >/dev/null 2>&1; then
        echo "not yet: there is no bridge called br0."
        echo "         the connectivity can be faked without one; the shape cannot,"
        echo "         and the shape is what Docker actually builds."
        exit 1
      fi

      enslaved=$(ip link show master br0 2>/dev/null | grep -c '^[0-9]' || true)
      if [ "${enslaved:-0}" -lt 2 ]; then
        echo "not yet: br0 has $enslaved interface(s) enslaved to it, expected 2."
        echo "         each namespace needs its own veth pair: one end inside the"
        echo "         namespace, the other end a port on the bridge."
        exit 1
      fi

      for ns in app1 app2; do
        if ! ip netns exec "$ns" ip -br addr show 2>/dev/null | grep -q '10\.77\.0\.'; then
          echo "not yet: $ns has no address in 10.77.0.0/24."
          ip netns exec "$ns" ip -br addr show 2>&1 | sed 's/^/         /'
          exit 1
        fi
      done

      # 2. Namespace to namespace, across the bridge.
      a2=$(ip netns exec app2 ip -4 -br addr show 2>/dev/null \
             | grep -o '10\.77\.0\.[0-9]*' | head -1)
      if [ -z "$a2" ]; then
        echo "not yet: could not find app2's address in 10.77.0.0/24"
        exit 1
      fi
      if ! ip netns exec app1 ping -c1 -W2 "$a2" >/dev/null 2>&1; then
        echo "not yet: app1 cannot ping app2 at $a2."
        echo "         both ends of both veth pairs have to be up — including the"
        echo "         end on the bridge, which is easy to leave down."
        exit 1
      fi

      # 3. Namespace to this box: needs a default route out of the namespace.
      body=$(ip netns exec app1 curl -s -m 5 http://172.31.0.10:8080/ 2>&1 || true)
      if ! printf '%s' "$body" | grep -q 'lab-net-2026'; then
        echo "not yet: app1 cannot reach the service on 172.31.0.10:8080."
        echo "         app1 needs a default route pointing at the bridge address,"
        echo "         and the box needs to be willing to forward."
        echo "         net.ipv4.ip_forward is currently $(cat /proc/sys/net/ipv4/ip_forward)"
        exit 1
      fi

      # 4. Namespace to the peer box: needs forwarding AND source NAT, because
      #    the peer has no route back to 10.77.0.0/24.
      if ! ip netns exec app1 ping -c1 -W3 172.31.0.11 >/dev/null 2>&1; then
        echo "not yet: app1 cannot reach the peer box at 172.31.0.11."
        echo "         forwarding alone is not enough here. The peer sees a packet"
        echo "         from 10.77.0.x, has no route to that network, and its reply"
        echo "         goes nowhere. Something has to rewrite the source address."
        exit 1
      fi

      echo "PASS — br0 carries both namespaces, they reach each other, they reach"
      echo "       this box, and their traffic is translated on the way to the peer."
