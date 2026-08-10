---
kind: lesson
title: "everyone can reach the service except the network it lives on"
description: |
  The published address works from outside. From a machine sitting next to the
  service, on the same subnet, the same address does not. The DNAT rule fires
  correctly in both cases — and in one of them the reply comes back wearing the
  wrong return address.
name: nat-and-hairpin
slug: nat-and-hairpin
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

      systemctl stop svc-web.service 2>/dev/null || true
      for ns in svc client outside; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del br-svc 2>/dev/null || true
      ip link del to-out 2>/dev/null || true
      ip link del pub0 2>/dev/null || true
      nft delete table ip pubnat 2>/dev/null || true

      # The internal network: a bridge, the service, and a client beside it.
      ip link add br-svc type bridge
      ip addr add 10.88.0.1/24 dev br-svc
      ip link set br-svc up

      for pair in "svc 5" "client 6"; do
        ns=${pair% *}; host=${pair#* }
        ip netns add "$ns"
        ip link add "veth-$ns" type veth peer name eth0-in
        ip link set eth0-in netns "$ns"
        ip link set "veth-$ns" master br-svc
        ip link set "veth-$ns" up
        ip netns exec "$ns" ip link set lo up
        ip netns exec "$ns" ip addr add "10.88.0.$host/24" dev eth0-in
        ip netns exec "$ns" ip link set eth0-in up
        ip netns exec "$ns" ip route add default via 10.88.0.1
      done

      # The outside world: one more namespace, off the internal subnet.
      ip netns add outside
      ip link add to-out type veth peer name out-in
      ip link set out-in netns outside
      ip addr add 198.51.100.1/24 dev to-out
      ip link set to-out up
      ip netns exec outside ip link set lo up
      ip netns exec outside ip addr add 198.51.100.7/24 dev out-in
      ip netns exec outside ip link set out-in up
      ip netns exec outside ip route add default via 198.51.100.1

      # The published address. It lives on this box, not on the service.
      ip link add pub0 type dummy 2>/dev/null || true
      ip addr add 203.0.113.10/32 dev pub0
      ip link set pub0 up

      sysctl -w net.ipv4.ip_forward=1 >/dev/null

      # A frame bridged between two ports on the same subnet is never routed, so
      # it never passes the box's netfilter hooks and conntrack never sees it.
      # That is how an ordinary router behaves. The Docker daemon turns on
      # br_netfilter host-wide, which drags bridged frames through the ip hooks
      # as well and would quietly paper over this entire lesson — so it goes off
      # here, restoring the normal behaviour the fix has to cope with.
      sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true

      # The publication rule: anything arriving for 203.0.113.10:80 is rewritten
      # to the service. This part is correct and is not the bug.
      nft add table ip pubnat
      nft 'add chain ip pubnat pre  { type nat hook prerouting  priority -100 ; }'
      nft 'add chain ip pubnat post { type nat hook postrouting priority  100 ; }'
      nft add rule ip pubnat pre ip daddr 203.0.113.10 tcp dport 80 dnat to 10.88.0.5:8080

      install -d /srv/svc
      echo "published-svc-2026" > /srv/svc/index.html
      cat > /etc/systemd/system/svc-web.service <<'UNIT'
      [Unit]
      Description=the published service, inside the svc namespace
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/svc
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/svc
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now svc-web.service >/dev/null 2>&1
      sleep 1

      cat > /root/questions.txt <<'Q'
      A service runs in the namespace "svc" at 10.88.0.5:8080. It is published
      at 203.0.113.10:80 by a DNAT rule on this box.

      From outside, it works:

        ip netns exec outside curl http://203.0.113.10/

      From "client" — a machine on the service's own subnet, 10.88.0.6 — the
      same URL does not:

        ip netns exec client curl http://203.0.113.10/

      The DNAT rule fires in both cases; you can watch the counter climb with
      `nft list table ip pubnat`. Nothing is being filtered. The service is up
      and is serving the request that arrives.

      Make the published address work from the internal network as well, while
      keeping it working from outside.

      Do not change what the client asks for — it must keep using
      http://203.0.113.10/. Do not move the service and do not remove the DNAT
      rule; the publication is the thing being fixed, not removed.

      The service serves a page containing published-svc-2026.
      Q

      echo "scenario ready — 203.0.113.10 answers from outside, not from 10.88.0.6"
      nft list table ip pubnat | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # 1. The publication must still be a publication.
      if ! nft list table ip pubnat 2>/dev/null | grep -q 'dnat to 10.88.0.5:8080'; then
        echo "not yet: the DNAT rule for 203.0.113.10:80 is gone."
        echo "         removing the published address is not fixing it. Pointing the"
        echo "         client straight at 10.88.0.5:8080 is the same move by hand."
        exit 1
      fi

      # 2. The service must not have been moved out onto the box.
      if ! systemctl is-active --quiet svc-web.service; then
        echo "not yet: svc-web.service is not running — the service has to stay"
        echo "         where it was, inside the svc namespace."
        exit 1
      fi
      if ss -lnt 2>/dev/null | grep -q ':8080 '; then
        echo "not yet: something is now listening on :8080 in the box's own network"
        echo "         namespace. The service belongs in svc; binding a second copy"
        echo "         beside it sidesteps the routing problem instead of solving it."
        exit 1
      fi

      # 3. br_netfilter must stay off. Turning it on makes bridged frames
      #    traverse the ip hooks so conntrack un-translates the reply by
      #    accident. It passes this check and is not a fix — it is a host-wide
      #    change to how every bridge on the machine behaves, made to avoid
      #    writing one NAT rule.
      brnf=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 0)
      if [ "$brnf" != "0" ]; then
        echo "not yet: net.bridge.bridge-nf-call-iptables has been turned back on."
        echo "         that does make it work, by pulling every bridged frame on the"
        echo "         box through netfilter. It is a machine-wide change with a"
        echo "         performance cost, standing in for one rule about one service."
        exit 1
      fi

      # 4. Outside must keep working.
      out=$(ip netns exec outside curl -s -m 5 http://203.0.113.10/ 2>&1 || true)
      if ! printf '%s' "$out" | grep -q 'published-svc-2026'; then
        echo "not yet: 203.0.113.10 no longer answers from outside."
        echo "         that path worked before the change."
        exit 1
      fi

      # 5. The hairpin itself.
      cl=$(ip netns exec client curl -s -m 5 http://203.0.113.10/ 2>&1 || true)
      if ! printf '%s' "$cl" | grep -q 'published-svc-2026'; then
        echo "not yet: 10.88.0.6 still cannot reach 203.0.113.10."
        echo "         the request is being translated and delivered. Look at what"
        echo "         source address the service sees, and work out where its reply"
        echo "         goes and what the client makes of it when it arrives."
        exit 1
      fi

      echo "PASS — 203.0.113.10 serves both from outside and from the service's own"
      echo "       subnet, with the publication rule still in place."
