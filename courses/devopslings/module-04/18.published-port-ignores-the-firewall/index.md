---
kind: lesson
title: "the host firewall allows SSH only, and the container's admin UI is on the internet"
description: |
  The Docker host has a default-deny inbound firewall that admits SSH and
  nothing else. A pentest just reached the admin UI of a container on it, from
  outside, on the published port. The firewall is not broken. The packets for a
  published port never go where the firewall is standing.
name: published-port-ignores-the-firewall
slug: published-port-ignores-the-firewall
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
      L=/var/lib/dock1-lesson

      # ---- clean slate -------------------------------------------------
      units="dock1-firewall dock1-dockerd ctr-admin"
      for u in $units; do systemctl stop "$u.service" 2>/dev/null || true; done
      for u in $units; do systemctl reset-failed "$u.service" 2>/dev/null || true; done
      for l in br91-d br91-o br91; do ip link del "$l" 2>/dev/null || true; done
      for ns in dock1 ctr-admin office2 fwcheck; do ip netns del "$ns" 2>/dev/null || true; done
      rm -rf /etc/dock1 /srv/ctr-admin "$L"
      rm -f /usr/local/sbin/dockerd-sim
      for u in $units; do rm -f "/etc/systemd/system/$u.service"; done
      install -d /etc/dock1 /srv/ctr-admin "$L"

      # ---- the topology ------------------------------------------------
      #
      #   this box 10.91.0.1   ("the internet", and the pentester)  ┐
      #   office2  10.91.0.50  (the office VPN concentrator)        ├─ br91
      #   dock1    10.91.0.10  (the Docker host) ───────────────────┘
      #     └─ docker0 172.18.0.1/16 ── ctr-admin 172.18.0.2 :80  (admin UI)
      #        published as dock1:8080
      ip link add br91 address 02:00:00:91:00:01 type bridge
      ip addr add 10.91.0.1/24 dev br91
      # A second outside address, so "outside" is not one IP a rule can name.
      ip addr add 10.91.0.99/24 dev br91
      ip link set br91 up

      ip netns add dock1
      ip netns add ctr-admin
      ip netns add office2
      ip link add br91-d type veth peer name eth0 netns dock1
      ip link add br91-o type veth peer name eth0 netns office2
      for l in br91-d br91-o; do ip link set "$l" master br91 up; done

      ip netns exec office2 sh -c '
        ip link set lo up
        ip addr add 10.91.0.50/24 dev eth0 && ip link set eth0 up
      '
      ip netns exec dock1 sh -c '
        ip link set lo up
        ip addr add 10.91.0.10/24 dev eth0 && ip link set eth0 up
        ip link add docker0 type bridge
        ip addr add 172.18.0.1/16 dev docker0 && ip link set docker0 up
        sysctl -qw net.ipv4.ip_forward=1
      '
      ip link add vethc0 type veth peer name eth0 netns ctr-admin
      ip link set vethc0 netns dock1
      ip netns exec dock1 sh -c 'ip link set vethc0 master docker0 up'
      ip netns exec ctr-admin sh -c '
        ip link set lo up
        ip addr add 172.18.0.2/16 dev eth0 && ip link set eth0 up
        ip route add default via 172.18.0.1
      '

      echo "admin-ui-2026" > /srv/ctr-admin/index.html
      printf '[Unit]\nDescription=container: admin UI on :80\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/ctr-admin\nExecStart=/usr/bin/python3 -m http.server 80 --bind 172.18.0.2 --directory /srv/ctr-admin\nRestart=always\n' \
        > /etc/systemd/system/ctr-admin.service

      # ---- what dockerd does to iptables -------------------------------
      #
      # Modelled on dockerd's bridge driver: on every start it rebuilds its
      # own chains and puts its FORWARD jumps first, and it never touches
      # DOCKER-USER beyond creating it.
      cat > /usr/local/sbin/dockerd-sim <<'SH'
      #!/bin/sh
      # The iptables half of dockerd, for one container publishing 8080->80.
      set -e
      for c in DOCKER DOCKER-FORWARD DOCKER-USER; do iptables -N "$c" 2>/dev/null || true; done
      iptables -t nat -N DOCKER 2>/dev/null || true
      iptables -F DOCKER
      iptables -F DOCKER-FORWARD
      iptables -t nat -F DOCKER

      while iptables -D FORWARD -j DOCKER-USER 2>/dev/null; do :; done
      while iptables -D FORWARD -j DOCKER-FORWARD 2>/dev/null; do :; done
      iptables -I FORWARD 1 -j DOCKER-FORWARD
      iptables -I FORWARD 1 -j DOCKER-USER

      iptables -A DOCKER-FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      iptables -A DOCKER-FORWARD -o docker0 -j DOCKER
      iptables -A DOCKER-FORWARD -i docker0 -j ACCEPT
      iptables -A DOCKER -d 172.18.0.2/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 80 -j ACCEPT

      while iptables -t nat -D PREROUTING -m addrtype --dst-type LOCAL -j DOCKER 2>/dev/null; do :; done
      iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
      iptables -t nat -C POSTROUTING -s 172.18.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 172.18.0.0/16 ! -o docker0 -j MASQUERADE
      iptables -t nat -A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.18.0.2:80
      SH
      chmod 755 /usr/local/sbin/dockerd-sim
      sha256sum /usr/local/sbin/dockerd-sim | cut -d' ' -f1 > "$L/dockerd-sim.sha256"

      printf '[Unit]\nDescription=dockerd (iptables management only)\nAfter=dock1-firewall.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/dock1\nExecStart=/usr/local/sbin/dockerd-sim\n' \
        > /etc/systemd/system/dock1-dockerd.service

      # ---- the host firewall -------------------------------------------
      cat > /etc/dock1/rules.v4 <<'RULES'
      # dock1 — host firewall, loaded at boot by dock1-firewall.service,
      # before dockerd starts. Inbound: SSH only.
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      :DOCKER-USER - [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
      COMMIT
      RULES
      printf '[Unit]\nDescription=dock1 host firewall (/etc/dock1/rules.v4)\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/dock1\nExecStart=/usr/sbin/iptables-restore /etc/dock1/rules.v4\n' \
        > /etc/systemd/system/dock1-firewall.service

      systemctl daemon-reload
      systemctl start ctr-admin.service dock1-firewall.service dock1-dockerd.service

      for _ in $(seq 1 20); do
        curl -s -m 1 http://10.91.0.10:8080/ 2>/dev/null | grep -q admin-ui && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      dock1 (10.91.0.10, a namespace: ip netns exec dock1 ...) is a Docker
      host. Its host firewall, /etc/dock1/rules.v4, is loaded at boot before
      dockerd starts and admits SSH and nothing else:

        ip netns exec dock1 iptables -L INPUT -v -n

      One container on it, the admin UI, publishes port 8080. A pentest
      reached it from the internet (this box, 10.91.0.1):

        curl -s -m 3 http://10.91.0.10:8080/

      It must be reachable from the office only — the VPN concentrator at
      10.91.0.50:

        ip netns exec office2 curl -s -m 3 http://10.91.0.10:8080/

      Fix it so that it stays fixed when dockerd restarts and when dock1
      reboots (the grader does both before it checks). The container keeps
      running and keeps its published port: the office uses it. dockerd's
      behaviour (/usr/local/sbin/dockerd-sim) is not yours to edit.
      Q

      echo "scenario ready — INPUT admits SSH only, and 8080 answers the internet"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 150
    run: |
      L=/var/lib/dock1-lesson

      if [ "$(sha256sum /usr/local/sbin/dockerd-sim 2>/dev/null | cut -d' ' -f1)" != "$(cat "$L/dockerd-sim.sha256" 2>/dev/null)" ]; then
        echo "not yet: /usr/local/sbin/dockerd-sim has been edited. It stands in for"
        echo "         dockerd, which you do not get to rewrite: the next upgrade puts"
        echo "         its behaviour back. Restore it and work with what it does."
        exit 1
      fi
      if ! systemctl is-active --quiet ctr-admin.service; then
        echo "not yet: the admin UI container (ctr-admin.service) is not running."
        echo "         The office still needs it."
        exit 1
      fi

      outside() { curl -s -m 3 --interface "$1" http://10.91.0.10:8080/ 2>/dev/null | grep -q admin-ui; }
      live_blocked=1
      outside 10.91.0.1 && live_blocked=0

      # ---- reboot, then dockerd starts ---------------------------------
      #
      # Same order as boot: the host firewall's file, then dockerd. Anything
      # that was only ever in the live tables is gone after this, as it would be.
      ip netns exec dock1 sh -c '
        for t in filter nat mangle raw; do iptables -t $t -F; iptables -t $t -X; done
        iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
      '
      systemctl restart dock1-firewall.service 2>/dev/null || {
        echo "not yet: /etc/dock1/rules.v4 does not load:"
        ip netns exec dock1 iptables-restore --test /etc/dock1/rules.v4 2>&1 | head -3 | sed 's/^/           /'
        exit 1
      }
      systemctl restart dock1-dockerd.service

      if ! ip netns exec office2 curl -s -m 3 http://10.91.0.10:8080/ 2>/dev/null | grep -q admin-ui-2026; then
        echo "not yet: after a reboot and a dockerd start, the office (10.91.0.50) can"
        echo "         no longer reach the admin UI on 10.91.0.10:8080."
        exit 1
      fi

      for src in 10.91.0.1 10.91.0.99; do
        if outside "$src"; then
          echo "not yet: after a reboot and a dockerd start, the admin UI on"
          echo "         10.91.0.10:8080 answers from $src, outside the office."
          if [ "$live_blocked" -eq 1 ]; then
            echo "         It was blocked before the reboot. Whatever blocked it lived only"
            echo "         in the running tables, or in a chain dockerd rebuilds when it starts."
          else
            echo "         A connection to a published port is DNATed before the filter"
            echo "         chains see it — which chain does it cross, and by then what is its"
            echo "         destination port?"
            echo "           ip netns exec dock1 iptables -t nat -L -v -n"
            echo "           ip netns exec dock1 iptables -L FORWARD -v -n"
          fi
          exit 1
        fi
      done

      echo "PASS — through a reboot and a dockerd restart, the office reaches the admin UI"
      echo "       and nothing outside it does."
