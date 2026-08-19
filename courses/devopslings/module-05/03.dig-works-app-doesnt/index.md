---
kind: lesson
title: "dig resolves it, the application cannot, and both are telling the truth"
description: |
  The name resolves perfectly from the command line and the service next to it
  reports "Could not resolve host". Nothing is wrong with the resolver, the
  record, or the network. The two are not asking the same component.
name: dig-works-app-doesnt
slug: dig-works-app-doesnt
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
      systemctl stop svc-payments.service 2>/dev/null || true
      ip netns del paynet 2>/dev/null || true
      ip link del to-pay 2>/dev/null || true
      rm -f /etc/dnsmasq.d/lab.conf
      install -d /opt/payments /root/answers

      # ---- the "internal" network, in a namespace ----------------------
      ip netns add paynet
      ip link add to-pay type veth peer name in0
      ip link set in0 netns paynet

      ip addr add 10.70.0.1/24 dev to-pay
      ip link set to-pay up

      ip netns exec paynet ip link set lo up
      ip netns exec paynet ip addr add 10.70.0.6/24 dev in0
      ip netns exec paynet ip link set in0 up
      ip netns exec paynet ip route add default via 10.70.0.1

      # payments answers. It serves a known string.
      cat > /opt/payments/index.html <<'HTML'
      payments-canonical-2026
      HTML
      chmod 644 /opt/payments/index.html

      cat > /etc/systemd/system/svc-payments.service <<'UNIT'
      [Unit]
      Description=payments.internal
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/paynet
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 10.70.0.6 --directory /opt/payments
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now svc-payments.service >/dev/null 2>&1

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
      local=/internal/
      resolv-file=/etc/dnsmasq-upstream.conf
      address=/payments.internal/10.70.0.6
      CONF

      systemctl unmask dnsmasq.service >/dev/null 2>&1 || true
      systemctl enable --now dnsmasq.service >/dev/null 2>&1
      systemctl restart dnsmasq.service

      # resolv.conf is a bind mount in a container, so it is written in place
      # rather than replaced.
      printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:1\n' > /etc/resolv.conf

      # Overwrite nsswitch.conf to remove DNS from hosts resolution
      cat > /etc/nsswitch.conf <<'NSS'
      passwd:         files
      group:          files
      shadow:         files
      gshadow:        files

      hosts:          files myhostname
      networks:       files

      protocols:      db files
      services:       db files
      ethers:         db files
      rpc:            db files

      netgroup:       nis
      NSS

      # Wait for the resolver to actually be answering before handing the box
      # over, so the first thing the student runs is not a false negative.
      for _ in $(seq 1 20); do
        dig +short +time=1 +tries=1 payments.internal @127.0.0.1 2>/dev/null | grep -q 10.70.0.6 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The billing service cannot reach http://payments.internal:8080/ and reports
      "Could not resolve host". dig payments.internal returns 10.70.0.6 every time.
      The resolver, the record and the network are all fine.

      Make curl http://payments.internal:8080/ return the page containing
      "payments-canonical-2026".

      Then write /root/answers/resolution.md, one line, exactly this form:

        file=<the absolute path of the file that was wrong> missing=<the one word missing from it>

      Constraints, all of which matter:

        - do not add anything to /etc/hosts
        - do not change /etc/dnsmasq.d/lab.conf
        - getent hosts localhost must still work when you are finished

      dig and curl do not ask the same component. Find the one that curl asks.
      Q

      echo "scenario ready — dig answers, the application does not"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      # Check that /etc/hosts was not modified
      if grep -qE '(^|[[:space:]])payments\.internal([[:space:]]|$)' /etc/hosts; then
        echo "not yet: payments.internal was added to /etc/hosts."
        echo "         that makes this one name work and leaves every other name on the"
        echo "         box in exactly the same state. The next service to be added will"
        echo "         fail identically, and so will the one after that."
        exit 1
      fi

      # Check that the record is still present
      if ! grep -q 'address=/payments.internal/10.70.0.6' /etc/dnsmasq.d/lab.conf; then
        echo "not yet: the payments.internal record is gone from the resolver."
        echo "         the record was correct from the start — dig proved that before"
        echo "         you touched anything."
        exit 1
      fi

      # Check that the resolver is still running
      if ! systemctl is-active --quiet dnsmasq.service; then
        echo "not yet: the resolver is not running any more."
        echo "         it was answering correctly the whole time. Stopping it removes"
        echo "         the one part of this that was working."
        exit 1
      fi

      # Check that localhost still resolves
      if ! getent hosts localhost >/dev/null 2>&1; then
        echo "not yet: localhost no longer resolves."
        echo "         the files source was doing a real job on that line. Whatever"
        echo "         replaced it took /etc/hosts out of the lookup path with it."
        exit 1
      fi

      # Check that the application path can resolve the name
      # getent exits non-zero when the name does not resolve, which is exactly
      # the state this check exists to report. Without the guard, pipefail ends
      # the script here and the student is told nothing.
      addr=$(getent hosts payments.internal 2>/dev/null | head -1 | awk '{print $1}' || true)
      if [ "$addr" != "10.70.0.6" ]; then
        echo "not yet: the application path still cannot resolve payments.internal."
        echo "         dig talks to the DNS server directly and always did."
        echo "         getaddrinfo asks the sources listed on the hosts line of"
        echo "         /etc/nsswitch.conf, in order."
        echo "         if DNS is not named on that line, no amount of correct DNS"
        echo "         configuration is ever consulted."
        exit 1
      fi

      # Check that the page is actually served
      body=$(curl -s -m 5 http://payments.internal:8080/ 2>&1 || true)
      if ! echo "$body" | grep -q 'payments-canonical-2026'; then
        echo "not yet: payments.internal resolves now but the page did not come back."
        exit 1
      fi

      # Check the answer file
      if [ ! -f /root/answers/resolution.md ] || [ ! -s /root/answers/resolution.md ]; then
        echo "not yet: /root/answers/resolution.md is missing or empty."
        echo "         naming the file and the missing source is the point of this one."
        exit 1
      fi

      # Parse the answer file
      low=$(tr 'A-Z' 'a-z' < /root/answers/resolution.md)
      f=$(printf '%s' "$low" | sed -n 's|.*file=\([^ ]*\).*|\1|p')
      m=$(printf '%s' "$low" | sed -n 's|.*missing=\([a-z]*\).*|\1|p')

      if [ "$f" != "/etc/nsswitch.conf" ]; then
        echo "not yet: $f is not the file that was wrong."
        echo "         you changed something to make this work — name that file."
        exit 1
      fi

      if [ "$m" != "dns" ]; then
        echo "not yet: the word missing from the hosts line was the name of a source."
        echo "         it is one word."
        exit 1
      fi

      echo "PASS — payments.internal resolves through getaddrinfo now, the page is"
      echo "       served, localhost still resolves, and /etc/hosts was left alone."
