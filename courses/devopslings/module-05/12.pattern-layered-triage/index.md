---
kind: lesson
title: "one symptom, and the cause is somewhere in the stack"
description: |
  The payments API health check fails from this box. That is all you are told,
  and it is all you get told every time — because the fault is drawn at random
  from five, seeded at a different layer on every run. The drill is the ladder:
  frame, route, port, name, certificate, in that order, until one rung answers.
name: pattern-layered-triage
slug: pattern-layered-triage
createdAt: "2026-08-21"

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
      systemctl stop payments-api.service 2>/dev/null || true
      for ns in gw api; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del to-gw 2>/dev/null || true
      ip route del 10.94.1.0/24 2>/dev/null || true
      rm -f /etc/dnsmasq.d/*.conf /root/answers/triage.md
      install -d /opt/api /etc/api /etc/pki/api /var/lib/drill /root/answers

      # ---- the path ----------------------------------------------------
      #
      #   box ---- to-gw/gw-box ---- gw ---- gw-api/api0 ---- api
      #   10.94.0.1            10.94.0.2   10.94.1.1        10.94.1.9
      #
      # Two hops, because a triage ladder needs a layer 2 rung and a layer 3
      # rung that are not the same link. The first hop is where a neighbour
      # entry can be wrong; the second is where a router can drop.
      ip netns add gw
      ip netns add api

      ip link add to-gw type veth peer name gw-box
      ip link set gw-box netns gw
      ip addr add 10.94.0.1/24 dev to-gw
      ip link set to-gw up

      ip link add gw-api type veth peer name api0
      ip link set gw-api netns gw
      ip link set api0 netns api

      ip netns exec gw sh -c '
        ip link set lo up
        ip addr add 10.94.0.2/24 dev gw-box
        ip link set gw-box up
        ip addr add 10.94.1.1/24 dev gw-api
        ip link set gw-api up
        sysctl -qw net.ipv4.ip_forward=1
      '

      ip netns exec api sh -c '
        ip link set lo up
        ip addr add 10.94.1.9/24 dev api0
        ip link set api0 up
        ip route add default via 10.94.1.1
      '

      ip route add 10.94.1.0/24 via 10.94.0.2 dev to-gw

      # ---- the certificates ---------------------------------------------
      #
      # Two leaves from one CA. They differ only in the name they are good for,
      # which is what makes the TLS rung a name problem rather than a trust
      # problem: the chain verifies either way, and one of them is for a host
      # nobody is asking for.
      leaf() {
        openssl req -newkey rsa:2048 -nodes -keyout "/etc/pki/api/$1.key" \
          -out "/tmp/$1.csr" -subj "/CN=$2" 2>/dev/null
        openssl x509 -req -in "/tmp/$1.csr" -days 825 \
          -CA /etc/pki/api/ca.crt -CAkey /etc/pki/api/ca.key -CAcreateserial \
          -out "/etc/pki/api/$1.crt" \
          -extfile <(printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$2") 2>/dev/null
      }

      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/pki/api/ca.key -out /etc/pki/api/ca.crt \
        -subj "/CN=partner internal CA" 2>/dev/null
      leaf api api.partner.internal
      leaf legacy api-internal.partner.example
      rm -f /tmp/api.csr /tmp/legacy.csr

      cp /etc/pki/api/ca.crt /usr/local/share/ca-certificates/partner-internal-ca.crt
      update-ca-certificates >/dev/null 2>&1

      cat > /etc/api/tls.conf <<'CONF'
      # Which keypair the payments API presents. Both are signed by the partner
      # internal CA; they are issued for different hostnames.
      cert=/etc/pki/api/api.crt
      key=/etc/pki/api/api.key
      CONF

      # ---- the service ---------------------------------------------------
      cat > /opt/api/payments.py <<'PY'
      import http.server
      import ssl

      CONF = "/etc/api/tls.conf"


      def conf():
          out = {}
          with open(CONF) as fh:
              for line in fh:
                  line = line.strip()
                  if line and not line.startswith("#") and "=" in line:
                      k, v = line.split("=", 1)
                      out[k.strip()] = v.strip()
          return out


      class API(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_GET(self):
              body = b"payments-api ok\n" if self.path.startswith("/health") else b"payments-api\n"
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, *args):
              pass


      c = conf()
      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      ctx.load_cert_chain(c["cert"], c["key"])
      srv = http.server.ThreadingHTTPServer(("10.94.1.9", 8443), API)
      srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
      srv.serve_forever()
      PY

      printf '[Unit]\nDescription=payments API, over the gateway\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/api\nExecStart=/usr/bin/python3 /opt/api/payments.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/payments-api.service
      systemctl daemon-reload
      systemctl enable --now payments-api.service >/dev/null 2>&1

      # ---- the resolver ---------------------------------------------------
      up=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
      [ -n "$up" ] || up=1.1.1.1
      printf 'nameserver %s\n' "$up" > /etc/dnsmasq-upstream.conf

      cat > /etc/dnsmasq.d/partner.conf <<'DNS'
      # The partner zone, served locally.
      listen-address=127.0.0.1
      bind-interfaces
      no-hosts
      resolv-file=/etc/dnsmasq-upstream.conf

      address=/api.partner.internal/10.94.1.9
      DNS

      systemctl restart dnsmasq.service
      printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:1\n' > /etc/resolv.conf

      for _ in $(seq 1 20); do
        dig +short api.partner.internal @127.0.0.1 2>/dev/null | grep -q 10.94.1 && break
        sleep 0.5
      done

      # Everything works at this point. Prove it before breaking one thing, so a
      # scenario that failed to come up cannot be mistaken for the seeded fault.
      ok=""
      for _ in $(seq 1 20); do
        if curl -sS -m 3 https://api.partner.internal:8443/health 2>/dev/null | grep -q 'payments-api ok'; then
          ok=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ok" ]; then
        echo "the scenario did not come up healthy before the fault was seeded"
        exit 1
      fi

      # ---- seed one fault --------------------------------------------------
      #
      # Five candidates, one drawn per run. The drill is worthless if the answer
      # is the same twice, so the draw is from /dev/urandom and nothing about it
      # is written down in a form that reads back as a layer.
      faults="arp route firewall dns tls"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      case "$fault" in
        arp)
          # A permanent neighbour entry with a MAC nothing answers to. The frames
          # are addressed to a station that does not exist and the veth peer
          # drops them; nothing above layer 2 ever hears about it.
          ip neigh replace 10.94.0.2 lladdr 02:00:5e:00:53:99 dev to-gw nud permanent
          ;;
        route)
          # No specific route left, so the default route takes it — out of the
          # docker bridge, where 10.94.1.9 means nothing.
          ip route del 10.94.1.0/24 via 10.94.0.2 dev to-gw
          ;;
        firewall)
          # On the router, not on either endpoint: a drop in the forward chain
          # for one port. Ping crosses, the port does not.
          ip netns exec gw sh -c '
            nft add table inet drill
            nft "add chain inet drill forward { type filter hook forward priority 0 ; policy accept ; }"
            nft add rule inet drill forward tcp dport 8443 drop
          '
          ;;
        dns)
          # The name answers, with an address in the right subnet that no
          # interface owns. Everything below layer 7 is intact and aimed at the
          # wrong host.
          sed -i 's#^address=/api.partner.internal/.*#address=/api.partner.internal/10.94.1.99#' /etc/dnsmasq.d/partner.conf
          systemctl restart dnsmasq.service
          ;;
        tls)
          # The API presents the other certificate. The chain still verifies;
          # the name on it is not the name being asked for.
          sed -i -e 's#^cert=.*#cert=/etc/pki/api/legacy.crt#' -e 's#^key=.*#key=/etc/pki/api/legacy.key#' /etc/api/tls.conf
          systemctl restart payments-api.service
          ;;
      esac

      # The digest, not the name. The grader knows the five candidates and can
      # recover which one this is; a student who finds the file learns that a
      # fault was seeded, which they already know. This is obfuscation and not
      # a secret — the real gate is that the health check has to pass.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > /var/lib/drill/state
      chmod 600 /var/lib/drill/state

      cat > /root/questions.txt <<'Q'
      The payments API health check fails from this box:

        curl -sS -m 8 https://api.partner.internal:8443/health

      It should print "payments-api ok". Everything about this scenario worked a
      moment ago, and exactly one thing was then broken — drawn at random from
      five, and seeded somewhere between the frame leaving this box and the
      certificate the API presents.

      The path: this box (10.94.0.1) -> a router at 10.94.0.2 -> the API at
      10.94.1.9:8443, which is reached by the name api.partner.internal through
      the resolver on 127.0.0.1. The router and the API are in network
      namespaces on this box: `ip netns exec gw ...` and `ip netns exec api ...`
      reach them, and you may read anything in either.

      Two things to do.

      1. Make the health check pass, by repairing the thing that was broken.
         Not by routing around it: the name must still resolve through the
         resolver on 127.0.0.1, the traffic must still go via 10.94.0.2, the API
         must stay where it is, and the certificate must still verify against
         the partner internal CA for the name being asked for. `curl -k`, an
         /etc/hosts entry and a new CA are all ways of making the symptom go
         away without fixing anything.

      2. Write /root/answers/triage.md, exactly two lines:

           layer: <number>
           cause: <one word>

         layer is the OSI layer the fault sits at, as a number. cause is one of:

           arp | route | firewall | dns | tls

      Work the ladder in order rather than guessing, and let each rung rule out
      the ones below it:

        ip neigh          the frame has somewhere to go
        ip route get      the packet has a next hop
        ping              the two ends can reach each other at all
        nc -vz / nft      the port is open along the path
        dig / getent      the name answers, and answers correctly
        openssl s_client  the certificate is for the name you asked for

      Run this lesson again and the fault moves. That is the point: the drill is
      the ladder, not the answer.
      Q

      echo "scenario ready — one fault seeded, health check failing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # Which fault was seeded. The digest is matched against the five
      # candidates rather than stored as a word, so the feedback below can be
      # specific without the answer sitting in a file on the box.
      digest=$(cat /var/lib/drill/state 2>/dev/null || true)
      fault=""
      for cand in arp route firewall dns tls; do
        h=$(printf '%s' "$cand" | sha256sum | awk '{print $1}')
        [ "$h" = "$digest" ] && fault="$cand"
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/drill/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi

      # ---- the symptom ----------------------------------------------------
      body=$(curl -sS -m 12 https://api.partner.internal:8443/health 2>/dev/null || true)
      if ! echo "$body" | grep -q 'payments-api ok'; then
        echo "not yet: the health check still does not pass."
        case "$fault" in
          arp)
            echo "         Nothing that leaves this box is coming back. Start at the"
            echo "         first hop: ip neigh show 10.94.0.2 dev to-gw, and compare it"
            echo "         with the address the router actually has —"
            echo "         ip netns exec gw cat /sys/class/net/gw-box/address"
            ;;
          route)
            echo "         Ask where the packet would go before asking what happens to"
            echo "         it: ip route get 10.94.1.9."
            ;;
          firewall)
            echo "         The two ends can reach each other and one port cannot."
            echo "         ping 10.94.1.9 against nc -vz 10.94.1.9 8443, then look at"
            echo "         the machine in between: ip netns exec gw nft list ruleset."
            ;;
          dns)
            echo "         Compare the name with the address: curl against"
            echo "         https://10.94.1.9:8443/health --resolve, and dig +short"
            echo "         api.partner.internal. Both work and they disagree."
            ;;
          tls)
            echo "         The connection is established and the handshake is not."
            echo "         openssl s_client -connect 10.94.1.9:8443 -servername"
            echo "         api.partner.internal, and read the name on the certificate."
            ;;
        esac
        exit 1
      fi

      # ---- the sidesteps -------------------------------------------------
      if grep -qi 'api\.partner\.internal' /etc/hosts 2>/dev/null; then
        echo "not yet: /etc/hosts now has an entry for api.partner.internal."
        echo "         That bypasses the resolver instead of repairing it, and it is"
        echo "         invisible to every other machine with the same problem."
        exit 1
      fi

      if [ -f /root/.curlrc ] && grep -qiE '^[[:space:]]*(-k|insecure)' /root/.curlrc; then
        echo "not yet: /root/.curlrc turns off certificate verification."
        echo "         The check below would then pass with any certificate at all,"
        echo "         which is the opposite of what it is for."
        exit 1
      fi

      answer=$(dig +short api.partner.internal @127.0.0.1 2>/dev/null | tail -1)
      if [ "$answer" != "10.94.1.9" ]; then
        echo "not yet: the resolver on 127.0.0.1 answers api.partner.internal with"
        echo "         '${answer:-nothing}', and the API is at 10.94.1.9."
        exit 1
      fi

      hop=$(ip route get 10.94.1.9 2>/dev/null | head -1 || true)
      if ! echo "$hop" | grep -q 'via 10.94.0.2'; then
        echo "not yet: traffic to 10.94.1.9 does not go via the router at 10.94.0.2."
        echo "         ip route get says: ${hop:-nothing}"
        exit 1
      fi

      # The chain has to verify against the CA the scenario built, for the name
      # the client asks for. Trusting a new CA, or serving a certificate for
      # another host, both fail here.
      chain=$(echo | timeout 10 openssl s_client -connect 10.94.1.9:8443 \
                -servername api.partner.internal \
                -verify_hostname api.partner.internal \
                -CAfile /etc/pki/api/ca.crt 2>/dev/null | grep -c 'Verify return code: 0 (ok)' || true)
      if [ "$chain" -eq 0 ]; then
        echo "not yet: the certificate on 10.94.1.9:8443 does not verify for the name"
        echo "         api.partner.internal against the partner internal CA."
        echo "         openssl s_client -connect 10.94.1.9:8443 \\"
        echo "           -servername api.partner.internal -CAfile /etc/pki/api/ca.crt"
        echo "         will say which of the two it is: an untrusted chain, or a"
        echo "         certificate issued for some other host."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty."
        echo "         The repair is half of this one. The other half is being able to"
        echo "         say which layer it was on, which is what makes the next one"
        echo "         faster."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      layer=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*layer[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      cause=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*cause[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)

      if [ -z "$layer" ]; then
        echo "not yet: no layer line with a number in /root/answers/triage.md."
        exit 1
      fi
      if [ -z "$cause" ]; then
        echo "not yet: no cause line in /root/answers/triage.md. One of:"
        echo "         arp | route | firewall | dns | tls"
        exit 1
      fi

      # TLS is the one place where two answers are both defensible: the
      # handshake is presentation, the name in it is what the application asked
      # for. Everywhere else the layer is not arguable.
      case "$fault" in
        arp)      want_layer="2" ;;
        route)    want_layer="3" ;;
        firewall) want_layer="4" ;;
        dns)      want_layer="7" ;;
        tls)      want_layer="6 7" ;;
      esac

      fail=0

      if [ "$cause" != "$fault" ]; then
        fail=1
        echo "not yet: you said cause=$cause, and the health check passes, so"
        echo "         something was repaired. The one that was seeded was $fault."
        case "$cause" in
          arp|route|firewall|dns|tls)
            echo "         Both are on the ladder. Re-run the rung you skipped: the"
            echo "         first one that fails is the fault, and everything under it"
            echo "         is a consequence."
            ;;
          *)
            echo "         cause has to be one of: arp | route | firewall | dns | tls"
            ;;
        esac
      fi

      if ! echo " $want_layer " | grep -q " $layer "; then
        fail=1
        echo "not yet: you said layer=$layer."
        case "$fault" in
          arp)
            echo "         A neighbour entry maps an address to a MAC, and a MAC is a"
            echo "         station on a link: layer 2. The packet was formed correctly"
            echo "         and put in a frame nobody would answer."
            ;;
          route)
            echo "         Choosing a next hop for a destination address is layer 3."
            ;;
          firewall)
            echo "         The rule matched a TCP port, and ports are layer 4. The"
            echo "         addresses were fine — ping crossed the same path."
            ;;
          dns)
            echo "         Resolving a name to an address is layer 7. Nothing below it"
            echo "         was wrong: the wrong address was reached perfectly."
            ;;
          tls)
            echo "         The handshake is layer 6, and the name checked in it is"
            echo "         what the application asked for — 6 or 7 are both taken."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at the layer it lives on,"
      echo "       the name still resolves through the resolver, the path still runs"
      echo "       through the router, and the certificate still verifies."
