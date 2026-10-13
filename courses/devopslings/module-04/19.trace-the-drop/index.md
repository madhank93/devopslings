---
kind: lesson
title: "the allow rule is right there, and the database is still unreachable"
description: |
  The app tier cannot reach the database. The router's ruleset has a rule that
  allows exactly that traffic, and it has twenty-odd others across seven chains,
  three sets and two zones. Reading it top to bottom is how people lose an
  afternoon. The kernel will tell you, rule by rule, what it did with one
  packet — if you ask it to.
name: trace-the-drop
slug: trace-the-drop
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
      L=/var/lib/fw2-lesson

      # ---- clean slate -------------------------------------------------
      units="fw2-firewall db-postgres db-redis db-devserver"
      for u in $units; do systemctl stop "$u.service" 2>/dev/null || true; done
      for u in $units; do systemctl reset-failed "$u.service" 2>/dev/null || true; done
      for ns in apps fw2 db fwcheck; do ip netns del "$ns" 2>/dev/null || true; done
      rm -rf /etc/fw2 "$L" /root/answers/trace.md
      for u in $units; do rm -f "/etc/systemd/system/$u.service"; done
      install -d /etc/fw2 "$L" /root/answers

      # ---- the topology ------------------------------------------------
      #
      #   apps 10.92.1.30 ── apps0 10.92.1.1  fw2  10.92.2.1 db0 ── db 10.92.2.10
      #                                                              :5432 postgres
      #                                                              :6379 redis
      #                                                              :5001 a dev server
      ip netns add apps
      ip netns add fw2
      ip netns add db
      ip link add apps0 type veth peer name eth0 netns apps
      ip link set apps0 netns fw2
      ip link add db0 type veth peer name eth0 netns db
      ip link set db0 netns fw2
      ip netns exec fw2 sh -c '
        ip link set lo up
        ip addr add 10.92.1.1/24 dev apps0 && ip link set apps0 up
        ip addr add 10.92.2.1/24 dev db0 && ip link set db0 up
        sysctl -qw net.ipv4.ip_forward=1
      '
      for pair in "apps 10.92.1.30 10.92.1.1" "db 10.92.2.10 10.92.2.1"; do
        set -- $pair
        ip netns exec "$1" sh -c "
          ip link set lo up
          ip addr add $2/24 dev eth0 && ip link set eth0 up
          ip route add default via $3
          sysctl -qw net.ipv4.ip_forward=0
        "
      done

      for svc in "postgres 5432 db-postgres-ok" "redis 6379 db-redis-ok" "devserver 5001 dev-server-ok"; do
        set -- $svc
        printf '[Unit]\nDescription=db %s on :%s\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/db\nExecStart=/usr/bin/socat TCP-LISTEN:%s,bind=10.92.2.10,fork,reuseaddr SYSTEM:"echo %s"\nRestart=always\n' \
          "$1" "$2" "$2" "$3" > "/etc/systemd/system/db-$1.service"
      done

      # ---- the ruleset -------------------------------------------------
      cat > /etc/fw2/ruleset.nft <<'NFT'
      #!/usr/sbin/nft -f
      # fw2 — app/db zone firewall. Loaded at boot by fw2-firewall.service.

      destroy table inet fw2

      table inet fw2 {
        set ops_hosts {
          type ipv4_addr
          elements = { 10.92.9.5, 10.92.9.6 }
        }

        set db_ports {
          type inet_service
          elements = { 5432, 6379 }
        }

        set blocked_nets {
          type ipv4_addr
          flags interval
          elements = { 10.92.200.0/24, 192.0.2.0/24 }
        }

        chain input {
          type filter hook input priority filter; policy drop;
          iif "lo" accept
          ct state established,related accept
          ct state invalid drop
          ip saddr @ops_hosts tcp dport 22 accept
          icmp type echo-request limit rate 5/second accept
          counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;
          ct state established,related accept
          ct state invalid counter drop
          ip saddr @blocked_nets counter drop
          iifname "apps0" jump from_apps
          iifname "db0" jump from_db
          counter drop
        }

        chain from_apps {
          oifname "db0" jump baseline_cross_zone
          oifname "db0" jump apps_to_db
          counter drop
        }

        # Applied to every cross-zone flow before its zone-pair chain.
        chain baseline_cross_zone {
          # SEC-118: developer servers listen on 5000-5999 and must never be
          # reachable across zones.
          tcp dport 5000-5999 counter drop
          tcp dport { 23, 135, 139, 445 } counter drop
          udp dport { 69, 161 } counter drop
        }

        chain apps_to_db {
          ip daddr 10.92.2.10 tcp dport @db_ports counter accept
          # DB-77: exporters and sidecars on the db tier use unprivileged ports.
          ip daddr 10.92.2.0/24 tcp dport 1024-65535 counter accept
          icmp type echo-request accept
          counter drop
        }

        chain from_db {
          oifname "apps0" counter drop
          counter drop
        }

        chain output {
          type filter hook output priority filter; policy accept;
        }
      }
      NFT

      printf '[Unit]\nDescription=fw2 firewall (/etc/fw2/ruleset.nft)\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/fw2\nExecStart=/usr/sbin/nft -f /etc/fw2/ruleset.nft\nExecReload=/usr/sbin/nft -f /etc/fw2/ruleset.nft\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/fw2-firewall.service

      systemctl daemon-reload
      for u in $units; do systemctl start "$u.service"; done

      # The handle the kernel gave the culprit, for grading the answer.
      ip netns exec fw2 nft -a list chain inet fw2 baseline_cross_zone \
        | sed -n 's/.*tcp dport 5000-5999 .*# handle \([0-9]*\).*/\1/p' > "$L/culprit.handle"
      [ -s "$L/culprit.handle" ]

      cat > /root/questions.txt <<'Q'
      fw2 is the firewall between the app tier and the database tier (both
      namespaces: apps, db; fw2 too). Its ruleset is /etc/fw2/ruleset.nft,
      loaded at boot by fw2-firewall.service.

      The app tier can reach redis and cannot reach postgres:

        ip netns exec apps nc -w3 10.92.2.10 6379    # db-redis-ok
        ip netns exec apps nc -w3 10.92.2.10 5432    # nothing

      The ruleset has a rule that accepts apps -> db on both ports:

        ip netns exec fw2 nft list ruleset

      1. Find the rule that drops the postgres connection, and write
         /root/answers/trace.md:

           chain: <the chain the dropping rule is in>
           handle: <that rule's handle>

         Handles: ip netns exec fw2 nft -a list ruleset

      2. Make postgres reachable from the app tier, and keep it that way after
         a reboot of fw2. The dev server on db:5001 must stay unreachable from
         the app tier — SEC-118 still stands.
      Q

      echo "scenario ready — redis through fw2 works, postgres does not"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      L=/var/lib/fw2-lesson
      want_handle=$(cat "$L/culprit.handle" 2>/dev/null || true)

      # ---- the diagnosis -----------------------------------------------
      if [ ! -s /root/answers/trace.md ]; then
        echo "not yet: /root/answers/trace.md is missing. Name the chain and the handle"
        echo "         of the rule that drops apps -> db:5432 before changing anything."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/trace.md)
      chain=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*chain[[:space:]]*[:=][[:space:]]*\([a-z0-9_-]*\).*/\1/p' | head -1)
      handle=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*handle[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      if [ "$chain" != "baseline_cross_zone" ]; then
        echo "not yet: you named chain '${chain:-nothing}'."
        case "$chain" in
          apps_to_db)
            echo "         That chain holds the rule that would accept it. The packet never"
            echo "         gets there." ;;
          forward|from_apps)
            echo "         The packet passes through that chain on its way. It is dropped"
            echo "         by a rule in a chain it jumps to." ;;
          *)
            echo "         Ask the kernel instead of reading: set nftrace on one packet"
            echo "         and watch  ip netns exec fw2 nft -a monitor trace" ;;
        esac
        exit 1
      fi
      if [ "$handle" != "$want_handle" ]; then
        echo "not yet: right chain; handle '${handle:-nothing}' is not the rule that dropped"
        echo "         it. nft -a monitor trace prints the handle of the rule that gave the"
        echo "         verdict, and nft -a list prints every rule's handle."
        exit 1
      fi

      # ---- the repair --------------------------------------------------
      dev=$(ip netns exec apps nc -w3 10.92.2.10 5001 2>/dev/null || true)
      if printf '%s' "$dev" | grep -q dev-server-ok; then
        echo "not yet: the app tier now reaches the dev server on db:5001."
        echo "         SEC-118 still stands: 5000-5999 stays shut across zones. Let"
        echo "         postgres through without opening the rest of the range."
        exit 1
      fi
      if ! ip netns exec apps nc -w3 10.92.2.10 6379 2>/dev/null | grep -q db-redis-ok; then
        echo "not yet: the app tier no longer reaches redis on db:6379. It did before."
        exit 1
      fi
      if ! ip netns exec apps nc -w3 10.92.2.10 5432 2>/dev/null | grep -q db-postgres-ok; then
        echo "not yet: the app tier still cannot reach postgres on db:5432."
        echo "         An accept only helps if the packet reaches it before the drop you"
        echo "         named. Trace it again and see where it stops now."
        exit 1
      fi

      # ---- and after a reboot ------------------------------------------
      ip netns del fwcheck 2>/dev/null || true
      ip netns add fwcheck
      booted=$(ip netns exec fwcheck sh -c 'nft -f /etc/fw2/ruleset.nft && nft -s list ruleset' 2>&1 || true)
      ip netns del fwcheck 2>/dev/null || true
      running=$(ip netns exec fw2 nft -s list ruleset 2>/dev/null || true)
      if [ "$booted" != "$running" ]; then
        echo "not yet: postgres works now, and /etc/fw2/ruleset.nft does not load the"
        echo "         ruleset that is running (boot file <, running >):"
        diff <(printf '%s\n' "$booted") <(printf '%s\n' "$running") | grep '^[<>]' | head -12 | sed 's/^/           /' || true
        if printf '%s' "$running" | grep -q nftrace; then
          echo "         The trace rule is still live, too. Tracing is a debugging tool;"
          echo "         take it out when you are done."
        fi
        exit 1
      fi

      echo "PASS — the culprit is named by chain and handle, postgres and redis are"
      echo "       reachable, the dev range is still shut, and the boot file matches."
