---
kind: lesson
title: "the firewall rule is there, and its counter has never moved"
description: |
  Security asked for the admin console to be unreachable from the office LAN.
  A rule went into the firewall the same afternoon. The console is still
  reachable from the office, the rule's packet counter reads zero, and the rule
  is not wrong — it is in a chain these packets never visit.
name: rule-in-the-wrong-chain
slug: rule-in-the-wrong-chain
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
      systemctl stop fw1-firewall.service srv-app.service srv-admin.service 2>/dev/null || true
      systemctl reset-failed fw1-firewall.service srv-app.service srv-admin.service 2>/dev/null || true
      for ns in office fw1 srv fwcheck; do ip netns del "$ns" 2>/dev/null || true; done
      rm -rf /etc/fw1 /srv/srv1
      rm -f /etc/systemd/system/fw1-firewall.service /etc/systemd/system/srv-app.service \
            /etc/systemd/system/srv-admin.service
      install -d /etc/fw1 /srv/srv1/app /srv/srv1/admin

      # ---- the topology ------------------------------------------------
      #
      #   office 10.88.0.20 ── fw1 (router + firewall) ── srv 10.88.1.10
      #                       10.88.0.1 | 10.88.1.1        :8080 app, :9000 admin console
      #
      # Three namespaces, so the firewall is a box of its own and nothing here
      # touches this box's netfilter tables.
      ip netns add office
      ip netns add fw1
      ip netns add srv
      ip link add lan type veth peer name eth0 netns office
      ip link set lan netns fw1
      ip link add dmz type veth peer name eth0 netns srv
      ip link set dmz netns fw1

      ip netns exec fw1 sh -c '
        ip link set lo up
        ip addr add 10.88.0.1/24 dev lan && ip link set lan up
        ip addr add 10.88.1.1/24 dev dmz && ip link set dmz up
        sysctl -qw net.ipv4.ip_forward=1
      '
      for pair in "office 10.88.0.20 10.88.0.1" "srv 10.88.1.10 10.88.1.1"; do
        set -- $pair
        ip netns exec "$1" sh -c "
          ip link set lo up
          ip addr add $2/24 dev eth0 && ip link set eth0 up
          ip route add default via $3
          sysctl -qw net.ipv4.ip_forward=0
        "
      done

      echo "app-answers-2026" > /srv/srv1/app/index.html
      echo "admin-console-2026" > /srv/srv1/admin/index.html
      for svc in "app 8080" "admin 9000"; do
        set -- $svc
        printf '[Unit]\nDescription=srv %s on :%s\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/srv\nExecStart=/usr/bin/python3 -m http.server %s --bind 10.88.1.10 --directory /srv/srv1/%s\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
          "$1" "$2" "$2" "$1" > "/etc/systemd/system/srv-$1.service"
      done

      # ---- the firewall ------------------------------------------------
      cat > /etc/fw1/rules.v4 <<'RULES'
      # fw1 — loaded at boot by fw1-firewall.service (iptables-restore).
      *filter
      :INPUT ACCEPT [0:0]
      :FORWARD ACCEPT [0:0]
      :OUTPUT ACCEPT [0:0]
      # SEC-311: the admin console on srv (tcp/9000) must not be reachable
      # from the office LAN.
      -A INPUT -s 10.88.0.0/24 -p tcp -m tcp --dport 9000 -j DROP
      COMMIT
      RULES

      printf '[Unit]\nDescription=fw1 firewall (/etc/fw1/rules.v4)\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/fw1\nExecStart=/usr/sbin/iptables-restore /etc/fw1/rules.v4\nExecReload=/usr/sbin/iptables-restore /etc/fw1/rules.v4\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/fw1-firewall.service

      systemctl daemon-reload
      systemctl start srv-app.service srv-admin.service fw1-firewall.service

      for _ in $(seq 1 20); do
        ip netns exec office curl -s -m 1 http://10.88.1.10:9000/ 2>/dev/null | grep -q admin-console && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      fw1 is the router and firewall between the office LAN (10.88.0.0/24) and
      the server network (10.88.1.0/24). Its rules live in /etc/fw1/rules.v4
      and are loaded at boot by fw1-firewall.service.

      Security ticket SEC-311: the admin console on srv (10.88.1.10:9000) must
      not be reachable from the office. A rule was added for it. From the
      office:

        ip netns exec office curl -s -m 3 http://10.88.1.10:9000/    # still answers
        ip netns exec office curl -s -m 3 http://10.88.1.10:8080/    # must keep working

      The rule is in fw1's ruleset and its counter is zero:

        ip netns exec fw1 iptables -L -v -n

      Make the admin console unreachable from the office, leave the app
      reachable, and make it survive a reboot of fw1.

      srv belongs to the application team: the fix goes on fw1, not on srv,
      and the console keeps running.
      Q

      echo "scenario ready — the admin console answers the office, the rule's counter is 0"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ip netns exec srv iptables-save 2>/dev/null | grep -q '^-A'; then
        echo "not yet: srv has firewall rules of its own now."
        echo "         srv is the application team's server. Filtering on it works, and"
        echo "         it is not where the office/server boundary is: the next server"
        echo "         on 10.88.1.0/24 is unprotected. The rule belongs on fw1."
        exit 1
      fi

      if ! systemctl is-active --quiet srv-admin.service; then
        echo "not yet: the admin console (srv-admin.service) is not running."
        echo "         Stopping it is not blocking it — the server network still needs it."
        exit 1
      fi

      if ! ip netns exec office curl -s -m 3 http://10.88.1.10:8080/ 2>/dev/null | grep -q app-answers-2026; then
        echo "not yet: the office can no longer reach the app on 10.88.1.10:8080."
        echo "         Only the admin console was meant to be blocked."
        exit 1
      fi

      if ip netns exec office curl -s -m 3 http://10.88.1.10:9000/ 2>/dev/null | grep -q admin-console; then
        echo "not yet: the office still reaches the admin console on 10.88.1.10:9000."
        echo "         The rule matches office traffic to port 9000, and its counter"
        echo "         says no such packet has ever been checked against it. Where in"
        echo "         fw1 does a packet that is only passing through get filtered?"
        echo "           ip netns exec fw1 iptables -L -v -n"
        exit 1
      fi

      # ---- it is fw1's forwarding path that blocks it -------------------
      live=$(ip netns exec fw1 iptables-save 2>/dev/null || true)
      if ! printf '%s\n' "$live" | grep -E '^-A FORWARD ' | grep -E -- '--dport 9000' | grep -Eq -- '-j (DROP|REJECT)'; then
        echo "not yet: the console is unreachable from the office, and not by a rule in"
        echo "         fw1's FORWARD chain — the filter chain for traffic a router passes"
        echo "         on. The rules fw1 has now:"
        printf '%s\n' "$live" | grep '^-A' | sed 's/^/           /'
        exit 1
      fi

      # ---- and after a reboot ------------------------------------------
      ip netns del fwcheck 2>/dev/null || true
      ip netns add fwcheck
      booted=$(ip netns exec fwcheck sh -c 'iptables-restore /etc/fw1/rules.v4 && iptables-save' 2>&1 || true)
      ip netns del fwcheck 2>/dev/null || true
      if ! printf '%s\n' "$booted" | grep -E '^-A FORWARD ' | grep -E -- '--dport 9000' | grep -Eq -- '-j (DROP|REJECT)'; then
        echo "not yet: blocked now, and /etc/fw1/rules.v4 still has no FORWARD rule for"
        echo "         port 9000. fw1-firewall.service loads that file at boot; the next"
        echo "         reboot reopens the console."
        exit 1
      fi

      echo "PASS — the office cannot reach the admin console, still reaches the app, and"
      echo "       the FORWARD rule that does it is in the file fw1 boots from."
