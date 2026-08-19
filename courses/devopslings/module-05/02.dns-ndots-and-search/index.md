---
kind: lesson
title: "the resolver answers instantly, and it answers the wrong host"
description: |
  Resolution is slow and, worse, intermittently wrong. The DNS server is
  healthy and `dig @server` returns the right address every single time. The
  application still reaches a machine nobody deployed to.
name: dns-ndots-and-search
slug: dns-ndots-and-search
createdAt: "2026-08-10"

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
      systemctl stop svc-api.service 2>/dev/null || true
      ip netns del apinet 2>/dev/null || true
      ip link del to-api 2>/dev/null || true
      rm -f /etc/dnsmasq.d/lab.conf
      install -d /opt/api

      # ---- the "internal" network, in a namespace ----------------------
      ip netns add apinet
      ip link add to-api type veth peer name in0
      ip link set in0 netns apinet

      ip addr add 10.70.0.1/24 dev to-api
      ip link set to-api up

      ip netns exec apinet ip link set lo up
      ip netns exec apinet ip addr add 10.70.0.6/24 dev in0
      ip netns exec apinet ip link set in0 up
      ip netns exec apinet ip route add default via 10.70.0.1

      # api answers. It serves a known string.
      cat > /opt/api/index.html <<'HTML'
      api-canonical-2026
      HTML
      chmod 644 /opt/api/index.html

      cat > /etc/systemd/system/svc-api.service <<'UNIT'
      [Unit]
      Description=api.internal
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/apinet
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 10.70.0.6 --directory /opt/api
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now svc-api.service >/dev/null 2>&1

      # ---- a resolver that answers for real ----------------------------
      # Docker's own resolver is kept as the upstream so that names outside
      # .internal still work. Everything under .internal is answered here and
      # never forwarded, so a name that is not configured is an immediate
      # NXDOMAIN rather than a slow trip to the internet.
      up=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
      [ -n "$up" ] || up=1.1.1.1
      printf 'nameserver %s\n' "$up" > /etc/dnsmasq-upstream.conf

      install -d /etc/dnsmasq.d
      cat > /etc/dnsmasq.d/lab.conf <<CONF
      listen-address=127.0.0.1
      bind-interfaces
      no-hosts
      log-queries
      local=/corp.internal/
      resolv-file=/etc/dnsmasq-upstream.conf
      address=/api.internal/10.70.0.6
      address=/corp.internal/10.70.0.99
      CONF

      systemctl unmask dnsmasq.service >/dev/null 2>&1 || true
      systemctl enable --now dnsmasq.service >/dev/null 2>&1
      systemctl restart dnsmasq.service

      # resolv.conf is a bind mount in a container, so it is written in place
      # rather than replaced.
      printf 'nameserver 127.0.0.1\nsearch corp.internal svc.internal internal\noptions ndots:5\n' > /etc/resolv.conf

      # Wait for the resolver to actually be answering before handing the box
      # over, so the first thing the student runs is not a false negative.
      for _ in $(seq 1 20); do
        dig +short +time=1 +tries=1 api.internal. @127.0.0.1 2>/dev/null | grep -q 10.70.0.6 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The application must reach http://api.internal:8080/ and get the page
      containing "api-canonical-2026". It currently reaches 10.70.0.99 instead.

      dig api.internal. @127.0.0.1 returns the correct address every time.

      The fix is in /etc/resolv.conf. Do not change /etc/dnsmasq.d/lab.conf,
      do not add anything to /etc/hosts, and keep the search line present.

      The corp.internal wildcard belongs to another team. In a real network you
      could not delete it even if you wanted to, so this box is what you fix.
      Q

      echo "scenario ready — api.internal resolves to the wrong host"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # Stopping the resolver makes the wrong answer go away by making every
      # answer go away, so it is ruled out before anything else is checked.
      if ! systemctl is-active --quiet dnsmasq.service; then
        echo "not yet: the resolver on this box is not running any more."
        echo "         with nothing answering, api.internal does not resolve to the"
        echo "         wrong host — it does not resolve at all. That is not the fix."
        exit 1
      fi

      # Check that the search line is still present
      if ! grep -q '^search ' /etc/resolv.conf; then
        echo "not yet: the search line is gone from /etc/resolv.conf."
        echo "         deleting it does make the wrong answer stop, and it also breaks"
        echo "         every short name on this box. The search list was not the fault."
        exit 1
      fi

      # Check that /etc/hosts was not modified
      if grep -qE '(^|[[:space:]])api\.internal([[:space:]]|$)' /etc/hosts; then
        echo "not yet: api.internal was added to /etc/hosts."
        echo "         that bypasses the resolver instead of fixing it, and it will not"
        echo "         travel with the application to any other machine."
        exit 1
      fi

      # Check that the wildcard is still present
      if ! grep -q 'address=/corp.internal/10.70.0.99' /etc/dnsmasq.d/lab.conf; then
        echo "not yet: the corp.internal wildcard has been removed from the resolver."
        echo "         in a real network that record belongs to somebody else and you"
        echo "         cannot delete it. Fix this box instead."
        exit 1
      fi

      # Check that the name resolves to the right address through normal resolution
      addr=$(getent hosts api.internal | head -1 | awk '{print $1}')
      if [ "$addr" != "10.70.0.6" ]; then
        echo "not yet: api.internal still resolves to $addr, not 10.70.0.6."
        echo "         getent applies the search list, dig does not."
        echo "         dig looked correct all along because it was not using search."
        exit 1
      fi

      # The right address is necessary and not sufficient. Reordering the search
      # list also lands on 10.70.0.6, and still asks the resolver for a name
      # under corp.internal first — the wasted round trip this lesson is about.
      # dnsmasq logs every query it answers, so the expansion is visible.
      # A journal cursor rather than a timestamp: --since has one-second
      # granularity, which is coarse enough to sweep in the getent from the
      # check above and count its queries as this one's.
      cur=$(journalctl -u dnsmasq --no-pager -n 0 --show-cursor 2>/dev/null \
            | sed -n 's/^-- cursor: //p')
      getent hosts api.internal >/dev/null 2>&1 || true
      sleep 1
      # Only A queries are graded. The AAAA half of the lookup walks the search
      # list even when the fix is correct: there is no AAAA record for
      # api.internal, so glibc gets NODATA and keeps trying the suffixes. That
      # is real dual-stack behaviour, not the fault being taught here.
      expanded=$(journalctl -u dnsmasq --after-cursor "$cur" --no-pager 2>/dev/null \
                 | grep -c 'query\[A\] api\.internal\.[a-z]' || true)
      if [ "${expanded:-0}" -gt 0 ]; then
        echo "not yet: api.internal is still being expanded against the search list"
        echo "         before it is tried as written. The resolver was asked for $expanded"
        echo "         suffixed name(s) that nobody wanted:"
        journalctl -u dnsmasq --after-cursor "$cur" --no-pager 2>/dev/null \
          | grep 'query\[' | tail -5 | sed 's/^/           /'
        echo "         the address is right now, and the box is still asking a"
        echo "         question it should never have asked."
        exit 1
      fi

      # Check that the page is actually served
      body=$(curl -s -m 5 http://api.internal:8080/ 2>&1 || true)
      if ! echo "$body" | grep -q 'api-canonical-2026'; then
        echo "not yet: api.internal resolves correctly now but the page did not come back."
        exit 1
      fi

      echo "PASS — api.internal resolves to 10.70.0.6 on the first query and serves"
      echo "       the canonical page, with the search list and the wildcard both"
      echo "       still in place."
