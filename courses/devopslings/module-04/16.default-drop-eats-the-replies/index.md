---
kind: lesson
title: "after hardening, the server serves fine and cannot fetch anything"
description: |
  The CIS hardening pass gave the web server a default-deny inbound firewall
  with exactly two holes: SSH and HTTP. The site still loads. Every deploy since
  has failed, because the server can no longer download anything — its
  connections go out and the answers are refused at the door, as strangers.
name: default-drop-eats-the-replies
slug: default-drop-eats-the-replies
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
      units="web1-firewall web1-site web1-debug web1-devserver pkg-mirror artifact-store"
      for u in $units; do systemctl stop "$u.service" 2>/dev/null || true; done
      for u in $units; do systemctl reset-failed "$u.service" 2>/dev/null || true; done
      ip link del to-web1 2>/dev/null || true
      for ns in web1 fwcheck; do ip netns del "$ns" 2>/dev/null || true; done
      rm -rf /etc/web1 /srv/web1lab
      for u in $units; do rm -f "/etc/systemd/system/$u.service"; done
      install -d /etc/web1 /srv/web1lab/site /srv/web1lab/mirror /srv/web1lab/artifacts

      # ---- the topology ------------------------------------------------
      #
      #   this box 10.89.0.1 ─── to-web1 ─── web1 10.89.0.10
      #     :8081 package mirror                :80   the site (public)
      #     :8082 artifact store                :22   ssh (nothing listens; allowed)
      #                                         :6060 debug endpoint (internal only)
      #                                         :41000 a dev server someone left running
      #
      # web1 is a namespace with its own netfilter, standing in for a server.
      ip netns add web1
      ip link add to-web1 type veth peer name eth0 netns web1
      ip addr add 10.89.0.1/24 dev to-web1
      # A second address for the grader's probes, so one can use source port
      # 8081 without colliding with the mirror listening on 10.89.0.1:8081.
      ip addr add 10.89.0.2/24 dev to-web1
      ip link set to-web1 up
      ip netns exec web1 sh -c '
        ip link set lo up
        ip addr add 10.89.0.10/24 dev eth0 && ip link set eth0 up
        ip route add default via 10.89.0.1
      '

      echo "web1-site-2026" > /srv/web1lab/site/index.html
      echo "mirror-package-2026" > /srv/web1lab/mirror/index.html
      echo "artifact-2026" > /srv/web1lab/artifacts/index.html

      unit() {
        # name, description, netns-or-empty, command
        ns_line=""
        [ -n "$3" ] && ns_line="NetworkNamespacePath=/run/netns/$3\n"
        printf "[Unit]\nDescription=%s\nAfter=network.target\n\n[Service]\n${ns_line}ExecStart=%s\nRestart=always\n" \
          "$2" "$4" > "/etc/systemd/system/$1.service"
      }
      unit web1-site      "web1 public site :80"         web1 "/usr/bin/python3 -m http.server 80 --bind 10.89.0.10 --directory /srv/web1lab/site"
      unit web1-debug     "web1 debug endpoint :6060"    web1 "/usr/bin/python3 -m http.server 6060 --bind 10.89.0.10 --directory /srv/web1lab/site"
      unit web1-devserver "web1 forgotten dev server"    web1 "/usr/bin/python3 -m http.server 41000 --bind 10.89.0.10 --directory /srv/web1lab/site"
      unit pkg-mirror     "package mirror :8081"         ""   "/usr/bin/python3 -m http.server 8081 --bind 10.89.0.1 --directory /srv/web1lab/mirror"
      unit artifact-store "artifact store :8082"         ""   "/usr/bin/python3 -m http.server 8082 --bind 10.89.0.1 --directory /srv/web1lab/artifacts"

      # ---- the hardening -----------------------------------------------
      cat > /etc/web1/rules.v4 <<'RULES'
      # web1 — loaded at boot by web1-firewall.service (iptables-restore).
      # CIS 3.5: default-deny inbound; allow only what this host serves.
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      -A INPUT -i lo -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
      -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
      COMMIT
      RULES

      printf '[Unit]\nDescription=web1 firewall (/etc/web1/rules.v4)\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nNetworkNamespacePath=/run/netns/web1\nExecStart=/usr/sbin/iptables-restore /etc/web1/rules.v4\nExecReload=/usr/sbin/iptables-restore /etc/web1/rules.v4\n' \
        > /etc/systemd/system/web1-firewall.service

      systemctl daemon-reload
      for u in $units; do systemctl start "$u.service"; done

      for _ in $(seq 1 20); do
        curl -s -m 1 http://10.89.0.10/ 2>/dev/null | grep -q web1-site && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      web1 (10.89.0.10, a namespace: ip netns exec web1 ...) went through the
      CIS hardening pass yesterday. Its firewall is /etc/web1/rules.v4, loaded
      at boot by web1-firewall.service.

      The site is fine:

        curl -s http://10.89.0.10/

      Every deploy since has failed. The deploy runs on web1, pulls a package
      from the mirror and pushes the build to the artifact store, both on this
      box:

        ip netns exec web1 curl -s -m 5 http://10.89.0.1:8081/
        ip netns exec web1 curl -s -m 5 http://10.89.0.1:8082/

      Both hang. Nothing filters on this box, and OUTPUT on web1 is ACCEPT.

      Make web1 able to reach both again, and keep it that way after a reboot.

      The hardening stays: inbound is default-deny. web1 also runs a debug
      endpoint on :6060 and a forgotten dev server on :41000, and neither may
      become reachable from anywhere else.
      Q

      echo "scenario ready — web1 serves, and cannot fetch"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ! ip netns exec web1 iptables -S INPUT 2>/dev/null | grep -qx -- '-P INPUT DROP'; then
        echo "not yet: web1's INPUT policy is no longer DROP."
        echo "         That fixes the deploy by undoing the hardening. The point was a"
        echo "         default-deny inbound; keep it and let the right packets in."
        exit 1
      fi

      for port in 6060 41000; do
        if curl -s -m 2 "http://10.89.0.10:$port/" 2>/dev/null | grep -q web1-site; then
          echo "not yet: web1's :$port answers from this box."
          echo "         Accepting by source address, or opening a range of ports for"
          echo "         replies to come back to, lets in everything else that lands there."
          exit 1
        fi
      done

      # A stateless hole for the mirror's source port also admits anyone who
      # simply sends *from* that port.
      if printf 'GET / HTTP/1.0\r\n\r\n' | timeout 3 nc -w2 -p 8081 -s 10.89.0.2 10.89.0.10 6060 2>/dev/null | grep -q web1-site; then
        echo "not yet: web1's internal :6060 answers a connection whose source port is 8081."
        echo "         A rule accepting packets *from* port 8081 cannot tell a reply from"
        echo "         the mirror from an attacker who picks that source port. The kernel"
        echo "         already knows which packets are replies to web1's own connections."
        exit 1
      fi

      if ! curl -s -m 3 http://10.89.0.10/ 2>/dev/null | grep -q web1-site-2026; then
        echo "not yet: the site on web1:80 no longer answers from outside."
        exit 1
      fi

      for pair in "8081 mirror-package-2026 package_mirror" "8082 artifact-2026 artifact_store"; do
        set -- $pair
        if ! ip netns exec web1 curl -s -m 5 "http://10.89.0.1:$1/" 2>/dev/null | grep -q "$2"; then
          echo "not yet: web1 still cannot reach the ${3/_/ } on 10.89.0.1:$1."
          echo "         web1 sends the SYN. Where does the SYN-ACK coming back go?"
          echo "           ip netns exec web1 iptables -L INPUT -v -n"
          exit 1
        fi
      done

      # ---- and after a reboot ------------------------------------------
      ip netns del fwcheck 2>/dev/null || true
      ip netns add fwcheck
      booted=$(ip netns exec fwcheck sh -c 'iptables-restore /etc/web1/rules.v4 && iptables -S INPUT' 2>&1 || true)
      ip netns del fwcheck 2>/dev/null || true
      if ! printf '%s\n' "$booted" | grep -qx -- '-P INPUT DROP' \
         || ! printf '%s\n' "$booted" | grep -E -- '--(ctstate|state) ' | grep -E 'ESTABLISHED' | grep -q -- '-j ACCEPT'; then
        echo "not yet: it works now, and /etc/web1/rules.v4 does not load it: after a"
        echo "         reboot web1 boots with"
        printf '%s\n' "$booted" | sed 's/^/           /'
        exit 1
      fi

      echo "PASS — web1 reaches the mirror and the artifact store, inbound is still"
      echo "       default-deny with :6060 and :41000 shut, and the boot file says so."
