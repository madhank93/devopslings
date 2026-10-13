---
kind: lesson
title: "iptables says the port is allowed, and the port is blocked"
description: |
  The API tier's firewall was migrated to a managed ruleset last month. The new
  load balancer cannot reach the API. `iptables -L` shows the rule that allows
  it, in the right chain, ahead of the policy. Every word of that output is
  true — of one of the two firewalls this host is running.
name: two-firewalls-one-box
slug: two-firewalls-one-box
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
      units="api1-firewall api1-legacy-fw api1-api api1-metrics"
      for u in $units; do systemctl stop "$u.service" 2>/dev/null || true; done
      for u in $units; do systemctl disable "$u.service" 2>/dev/null || true; done
      for u in $units; do systemctl reset-failed "$u.service" 2>/dev/null || true; done
      ip link del to-api1 2>/dev/null || true
      for ns in api1 fwcheck; do ip netns del "$ns" 2>/dev/null || true; done
      rm -rf /etc/api1 /srv/api1lab
      for u in $units; do rm -f "/etc/systemd/system/$u.service"; done
      install -d /etc/api1 /srv/api1lab

      # ---- the topology ------------------------------------------------
      #
      #   this box 10.90.0.1 (the new load balancer) ── to-api1 ── api1 10.90.0.10
      #                                                             :8080 API
      #                                                             :9090 metrics (internal)
      ip netns add api1
      ip link add to-api1 type veth peer name eth0 netns api1
      ip addr add 10.90.0.1/24 dev to-api1
      ip link set to-api1 up
      ip netns exec api1 sh -c '
        ip link set lo up
        ip addr add 10.90.0.10/24 dev eth0 && ip link set eth0 up
        ip route add default via 10.90.0.1
      '

      echo "api-answers-2026" > /srv/api1lab/index.html
      for svc in "api 8080" "metrics 9090"; do
        set -- $svc
        printf '[Unit]\nDescription=api1 %s on :%s\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/api1\nExecStart=/usr/bin/python3 -m http.server %s --bind 10.90.0.10 --directory /srv/api1lab\nRestart=always\n' \
          "$1" "$2" "$2" > "/etc/systemd/system/api1-$1.service"
      done

      # ---- the managed firewall ----------------------------------------
      #
      # iptables in Debian is iptables-nft: these rules live in nftables.
      cat > /etc/api1/rules.v4 <<'RULES'
      # api1 — managed ruleset (FW-2207, migrated from the 2019 script).
      # Loaded at boot by api1-firewall.service.
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
      -A INPUT -s 10.90.0.0/24 -p tcp -m tcp --dport 8080 -j ACCEPT
      COMMIT
      RULES
      printf '[Unit]\nDescription=api1 firewall (/etc/api1/rules.v4)\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/api1\nExecStart=/usr/sbin/iptables-restore /etc/api1/rules.v4\nExecReload=/usr/sbin/iptables-restore /etc/api1/rules.v4\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/api1-firewall.service

      # ---- the one nobody removed --------------------------------------
      cat > /etc/api1/legacy-fw.sh <<'SH'
      #!/bin/sh
      # API tier firewall (2019). Only the load balancer pair may reach the API.
      # Written for the jessie hosts, which predate nftables.
      IPT=/usr/sbin/iptables-legacy
      $IPT -F INPUT
      $IPT -A INPUT -p tcp --dport 8080 ! -s 10.90.9.0/24 -j DROP
      SH
      chmod 755 /etc/api1/legacy-fw.sh
      printf '[Unit]\nDescription=api tier firewall\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/api1\nExecStart=/etc/api1/legacy-fw.sh\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/api1-legacy-fw.service

      systemctl daemon-reload
      systemctl start api1-api.service api1-metrics.service
      systemctl enable --now api1-firewall.service api1-legacy-fw.service >/dev/null 2>&1

      cat > /root/questions.txt <<'Q'
      This box is the new load balancer for the API tier (10.90.0.1). api1
      (10.90.0.10, a namespace: ip netns exec api1 ...) is an API server. The
      load balancer cannot reach it:

        curl -s -m 5 http://10.90.0.10:8080/

      api1's firewall was migrated to a managed ruleset last month (FW-2207):
      /etc/api1/rules.v4, loaded at boot by api1-firewall.service. It allows
      8080 from 10.90.0.0/24, and the live ruleset agrees:

        ip netns exec api1 iptables -L INPUT -v -n

      Make the API reachable from this box, and keep it that way after a
      reboot of api1. The managed ruleset is the firewall of record: keep it,
      including its default-deny. api1's metrics port (9090) must stay
      unreachable from here.
      Q

      echo "scenario ready — the allow rule is right there, and 8080 is blocked"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ! ip netns exec api1 iptables -S INPUT 2>/dev/null | grep -qx -- '-P INPUT DROP'; then
        echo "not yet: api1's managed ruleset no longer has INPUT at DROP."
        echo "         That is the firewall of record. Keep it."
        exit 1
      fi
      if curl -s -m 2 http://10.90.0.10:9090/ 2>/dev/null | grep -q api-answers; then
        echo "not yet: api1's metrics port (9090) answers from this box. The managed"
        echo "         firewall is supposed to keep it shut."
        exit 1
      fi

      if ! curl -s -m 3 http://10.90.0.10:8080/ 2>/dev/null | grep -q api-answers-2026; then
        echo "not yet: this box still cannot reach the API on 10.90.0.10:8080."
        echo "         Read the first line of what iptables prints, not just the rules:"
        echo "           ip netns exec api1 iptables -L INPUT -n"
        exit 1
      fi

      legacy=$(ip netns exec api1 iptables-legacy-save 2>/dev/null | grep '^-A' || true)
      if [ -n "$legacy" ]; then
        echo "not yet: the API answers, and api1 still has rules in its legacy tables:"
        printf '%s\n' "$legacy" | sed 's/^/           /'
        echo "         Two rule sets, both enforced, one of them invisible to the tool"
        echo "         everyone runs. The next person to debug this host reads only one."
        exit 1
      fi

      # ---- and after a reboot ------------------------------------------
      if systemctl is-enabled api1-legacy-fw.service >/dev/null 2>&1; then
        ip netns del fwcheck 2>/dev/null || true
        ip netns add fwcheck
        replay=$(ip netns exec fwcheck sh -c '/etc/api1/legacy-fw.sh >/dev/null 2>&1; iptables-legacy-save' 2>/dev/null | grep '^-A' || true)
        ip netns del fwcheck 2>/dev/null || true
        if [ -n "$replay" ]; then
          echo "not yet: the legacy tables are clean now, and api1-legacy-fw.service is"
          echo "         still enabled. At the next boot it puts back:"
          printf '%s\n' "$replay" | sed 's/^/           /'
          exit 1
        fi
      fi

      echo "PASS — the load balancer reaches the API, the managed ruleset is the only"
      echo "       firewall on api1, and nothing will load the legacy one at boot."
