---
kind: lesson
title: "one dependency hangs, the other is refused, and both are the same firewall"
description: |
  Two calls out of the same service fail at the same moment. One waits thirty
  seconds and gives up; the other comes back before the log line finishes
  printing. Two rules, two behaviours, and the difference tells you which rule
  you are looking at before you have read any of them.
name: drop-versus-reject
slug: drop-versus-reject
createdAt: "2026-08-10"

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
      for u in dep-inventory dep-shipping dep-legacy; do
        systemctl stop "$u.service" 2>/dev/null || true
      done
      ip netns del deps 2>/dev/null || true
      ip link del to-deps 2>/dev/null || true
      nft delete table inet appfw 2>/dev/null || true
      install -d /opt/deps /root/answers

      # ---- the dependency network -------------------------------------
      ip netns add deps
      ip link add to-deps type veth peer name dep0
      ip link set dep0 netns deps
      ip addr add 10.80.0.1/24 dev to-deps
      ip link set to-deps up
      ip netns exec deps ip link set lo up
      ip netns exec deps ip addr add 10.80.0.5/24 dev dep0
      ip netns exec deps ip addr add 10.80.0.6/24 dev dep0
      ip netns exec deps ip addr add 10.80.0.9/24 dev dep0
      ip netns exec deps ip link set dep0 up
      ip netns exec deps ip route add default via 10.80.0.1

      # ---- the services -------------------------------------
      for row in "inventory 10.80.0.5 9001" "shipping 10.80.0.6 9002" "legacy 10.80.0.9 9003"; do
        # shellcheck disable=SC2086
        set -- $row
        n=$1 a=$2 p=$3
        install -d "/opt/deps/$n"
        printf '%s-canonical-2026\n' "$n" > "/opt/deps/$n/index.html"
        printf '[Unit]\nDescription=%s dependency\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/deps\nExecStart=/usr/bin/python3 -m http.server %s --bind %s --directory /opt/deps/%s\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' "$n" "$p" "$a" "$n" > "/etc/systemd/system/dep-$n.service"
      done
      systemctl daemon-reload
      for n in inventory shipping legacy; do
        systemctl enable --now "dep-$n.service" >/dev/null 2>&1
      done

      # ---- the firewall ------------------------------------------------
      nft add table inet appfw
      nft 'add chain inet appfw output { type filter hook output priority 0 ; policy accept ; }'
      nft add rule inet appfw output ip daddr 10.80.0.5 tcp dport 9001 drop
      nft add rule inet appfw output ip daddr 10.80.0.6 tcp dport 9002 reject with tcp reset
      nft add rule inet appfw output ip daddr 10.80.0.9 drop

      # Wait for the services to be answering before handing the box
      # over, so the first thing the student runs is not a false negative.
      for _ in $(seq 1 20); do
        ip netns exec deps curl -s -m 1 http://10.80.0.9:9003/ 2>/dev/null | grep -q legacy-canonical-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The orders service calls two dependencies and both calls started failing at
      the same moment.

      curl http://10.80.0.5:9001/ — the inventory API — hangs and eventually gives
      up.

      curl http://10.80.0.6:9002/ — the shipping API — comes back refused,
      immediately.

      Both dependency hosts are up and both services are running correctly.

      Make both of them return their pages.

      10.80.0.9 is a decommissioned host that is quarantined on purpose. It must
      still be unreachable from this box when you are finished — so flushing the
      ruleset is not a fix.

      Then write /root/answers/blocked.md, exactly two lines:

        inventory: signature=<timeout|refused> rule=<drop|reject>
        shipping: signature=<timeout|refused> rule=<drop|reject>

      You can tell the two apart before you read a single rule. How long each
      call took is the evidence.
      Q

      echo "scenario ready — one hangs, one refuses"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # Check that the quarantine survives
      legacy=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://10.80.0.9:9003/ 2>/dev/null || true)

      if [ "$legacy" = "200" ]; then
        echo "not yet: 10.80.0.9 is reachable from this box again."
        echo "         that host is quarantined on purpose. Clearing the whole ruleset"
        echo "         does unblock the two dependencies, and it unblocks this as well."
        exit 1
      fi

      # Check that inventory answers
      inv=$(curl -s -m 8 http://10.80.0.5:9001/ 2>/dev/null || true)
      if ! echo "$inv" | grep -q 'inventory-canonical-2026'; then
        echo "not yet: the inventory API at 10.80.0.5:9001 still does not answer."
        exit 1
      fi

      # Check that shipping answers
      ship=$(curl -s -m 5 http://10.80.0.6:9002/ 2>/dev/null || true)
      if ! echo "$ship" | grep -q 'shipping-canonical-2026'; then
        echo "not yet: the shipping API at 10.80.0.6:9002 still does not answer."
        exit 1
      fi

      # Check that the answer file exists and is not empty
      if [ ! -s /root/answers/blocked.md ]; then
        echo "not yet: /root/answers/blocked.md is missing or empty."
        echo "         naming which signature came from which rule is half of this one."
        exit 1
      fi

      # Grade both lines
      fail=0
      for row in "inventory timeout drop" "shipping refused reject"; do
        # shellcheck disable=SC2086
        set -- $row
        name=$1 want_sig=$2 want_rule=$3
        line=$(grep -iE "^[[:space:]]*$name[[:space:]]*:" /root/answers/blocked.md | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: there is no '$name:' line in /root/answers/blocked.md."
          exit 1
        fi
        low=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
        sig=$(printf '%s' "$low" | sed -n 's/.*signature=\([^[:space:]]*\).*/\1/p')
        rule=$(printf '%s' "$low" | sed -n 's/.*rule=\([^[:space:]]*\).*/\1/p')
        if [ -z "$sig" ]; then
          echo "not yet: $name — signature field is missing from /root/answers/blocked.md."
          exit 1
        fi
        if [ -z "$rule" ]; then
          echo "not yet: $name — rule field is missing from /root/answers/blocked.md."
          exit 1
        fi
        if ! echo "$sig" | grep -qE '^(timeout|refused)$'; then
          echo "not yet: $name — signature must be one of timeout, refused."
          exit 1
        fi
        if ! echo "$rule" | grep -qE '^(drop|reject)$'; then
          echo "not yet: $name — rule must be one of drop, reject."
          exit 1
        fi
        if [ "$sig" != "$want_sig" ]; then
          fail=1
          if [ "$name" = "inventory" ]; then
            echo "not yet: inventory — you said signature=$sig."
            echo "         a rule that drops a packet sends nothing back at all. The client"
            echo "         is left waiting on a reply that was never going to come, and only"
            echo "         its own timeout ends the call."
          else
            echo "not yet: shipping — you said signature=$sig."
            echo "         that call came back faster than a round trip to a healthy server."
            echo "         Something answered it, and what it answered with was a refusal."
          fi
        fi
        if [ "$rule" != "$want_rule" ]; then
          fail=1
          if [ "$name" = "inventory" ]; then
            echo "not yet: inventory — you said rule=$rule."
            echo "         silence is what a drop looks like from the client. A reject is"
            echo "         never silent; it is the rule that takes the trouble to reply."
          else
            echo "not yet: shipping — you said rule=$rule."
            echo "         a drop would have made this hang. This one was answered, which"
            echo "         means a rule chose to send something back."
          fi
        fi
      done

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — both dependencies answer, 10.80.0.9 is still quarantined, and the"
      echo "       two signatures are matched to the rules that produced them."
