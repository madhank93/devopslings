---
kind: lesson
title: "curl -k works, and that is the whole problem"
description: |
  The deploy step cannot publish to the artifact gateway: certificate verify
  failed. The leaf certificate is valid for another two years, the CA is in the
  system store, and `curl -k` sails straight through. Two separate faults are
  hiding behind one error message — one on the server, which is not sending the
  whole chain, and one in the client, which is not sending the name.
name: tls-chain-and-sni
slug: tls-chain-and-sni
createdAt: "2026-08-19"

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
      systemctl stop vhosts.service 2>/dev/null || true
      rm -rf /opt/pki /opt/vhosts /etc/vhosts
      install -d /opt/pki /opt/vhosts /etc/vhosts /root/answers
      : > /var/log/vhosts.log

      # The gateway answers on this box's own lab address rather than on
      # loopback, because a client that connects to 127.0.0.1 is a client
      # nobody believes. The address is read rather than assumed so the lesson
      # does not depend on what Docker handed out.
      ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
      [ -n "$ip" ] || { echo "no global IPv4 address on this box"; exit 1; }
      echo "$ip" > /opt/vhosts/address

      # /etc/hosts is a bind mount in this sandbox, so it is rewritten in place
      # rather than with sed -i, which renames and would fail on the mount.
      grep -v -e 'artifacts\.corp' -e 'internal-tools\.corp' /etc/hosts > /tmp/hosts.new || true
      cat /tmp/hosts.new > /etc/hosts
      rm -f /tmp/hosts.new
      printf '%s artifacts.corp\n%s internal-tools.corp\n' "$ip" "$ip" >> /etc/hosts

      # ---- the PKI -----------------------------------------------------
      #
      # Three levels, because two would not teach anything: a root that ends up
      # in the system trust store, an issuing CA that signs the leaves and that
      # nothing trusts on its own, and the leaves themselves. The intermediate
      # is deliberately *not* installed as a trust anchor. It is the server's
      # job to send it, and a lesson that lets the student install it instead
      # teaches the habit that breaks every other client on the network.
      cd /opt/pki

      openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout root.key -out root.crt \
        -subj "/O=Corp/CN=Corp Root CA 2026" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

      openssl req -new -newkey rsa:2048 -nodes -sha256 \
        -keyout intermediate.key -out intermediate.csr \
        -subj "/O=Corp/CN=Corp Issuing CA 2026" >/dev/null 2>&1

      cat > /opt/pki/ca.ext <<'EXT'
      basicConstraints=critical,CA:TRUE,pathlen:0
      keyUsage=critical,keyCertSign,cRLSign
      subjectKeyIdentifier=hash
      authorityKeyIdentifier=keyid:always
      EXT

      openssl x509 -req -in intermediate.csr -sha256 -days 3650 \
        -CA root.crt -CAkey root.key -CAcreateserial \
        -extfile /opt/pki/ca.ext -out intermediate.crt >/dev/null 2>&1

      issue_leaf() {
        name=$1
        openssl req -new -newkey rsa:2048 -nodes -sha256 \
          -keyout "$name.key" -out "$name.csr" \
          -subj "/O=Corp/CN=$name" >/dev/null 2>&1
        cat > /opt/pki/leaf.ext <<EXT
      basicConstraints=critical,CA:FALSE
      keyUsage=critical,digitalSignature,keyEncipherment
      extendedKeyUsage=serverAuth
      subjectAltName=DNS:$name
      subjectKeyIdentifier=hash
      authorityKeyIdentifier=keyid:always
      EXT
        openssl x509 -req -in "$name.csr" -sha256 -days 825 \
          -CA intermediate.crt -CAkey intermediate.key -CAcreateserial \
          -extfile /opt/pki/leaf.ext -out "$name.crt" >/dev/null 2>&1
      }

      issue_leaf artifacts.corp
      issue_leaf internal-tools.corp

      # internal-tools was deployed by a team that knew what a chain file is.
      # It is here as the contrast: same CA, same box, same listener, and it
      # verifies.
      cat internal-tools.corp.crt intermediate.crt > internal-tools.corp.chain.crt

      chmod 600 /opt/pki/*.key

      # Only the root becomes a trust anchor. This is the state every laptop,
      # CI runner and container in the story is in.
      cp root.crt /usr/local/share/ca-certificates/corp-root.crt
      update-ca-certificates >/dev/null 2>&1

      # ---- the gateway -------------------------------------------------
      #
      # One listener, two virtual hosts, selected by the name in the TLS
      # ClientHello. The vhost that answers when no name arrives is the
      # default, and here that is internal-tools — which is exactly what makes
      # a client that connects to an IP address get somebody else's
      # certificate.
      cat > /etc/vhosts/vhosts.json <<'JSON'
      {
        "listen": 8443,
        "default": "internal-tools.corp",
        "sites": {
          "artifacts.corp": {
            "cert": "/opt/pki/artifacts.corp.crt",
            "key":  "/opt/pki/artifacts.corp.key"
          },
          "internal-tools.corp": {
            "cert": "/opt/pki/internal-tools.corp.chain.crt",
            "key":  "/opt/pki/internal-tools.corp.key"
          }
        }
      }
      JSON

      cat > /opt/vhosts/gateway.py <<'PY'
      import datetime
      import http.server
      import json
      import ssl

      CONF = "/etc/vhosts/vhosts.json"
      LOG = "/var/log/vhosts.log"

      conf = json.load(open(CONF))
      address = open("/opt/vhosts/address").read().strip()


      def context_for(site):
          ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
          ctx.load_cert_chain(site["cert"], site["key"])
          return ctx


      sites = {name: context_for(s) for name, s in conf["sites"].items()}


      def note(name):
          with open(LOG, "a") as fh:
              stamp = datetime.datetime.now().isoformat(timespec="seconds")
              fh.write("%s sni=%s\n" % (stamp, name or "-"))


      def pick_vhost(sock, name, ctx):
          note(name)
          if name in sites:
              sock.context = sites[name]


      class Gateway(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def _send(self, body):
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              self._send(b"vhost-gateway-2026\n")

          def do_PUT(self):
              self.do_POST()

          def do_POST(self):
              want = int(self.headers.get("Content-Length", "0"))
              got = 0
              while got < want:
                  chunk = self.rfile.read(min(65536, want - got))
                  if not chunk:
                      break
                  got += len(chunk)
              self._send(("published bytes=%d\n" % got).encode())

          def log_message(self, *args):
              pass


      default = sites[conf["default"]]
      default.sni_callback = pick_vhost

      httpd = http.server.ThreadingHTTPServer((address, conf["listen"]), Gateway)
      httpd.socket = default.wrap_socket(httpd.socket, server_side=True)
      httpd.serve_forever()
      PY

      printf '[Unit]\nDescription=TLS vhost gateway\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/python3 /opt/vhosts/gateway.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/vhosts.service
      systemctl daemon-reload
      systemctl enable --now vhosts.service >/dev/null 2>&1

      # ---- the deploy step ----------------------------------------------
      #
      # The address is pinned in the URL. That is the second fault, and it is
      # invisible until the first one is fixed: an IP literal in a URL means no
      # SNI on the wire, and no SNI means the default vhost answers.
      dd if=/dev/zero of=/root/build.tar.gz bs=1024 count=64 2>/dev/null

      cat > /usr/local/bin/publish <<PUB
      #!/bin/sh
      # Publishes the current build to the artifact gateway.
      # Address pinned during the resolver outage in June.
      set -e
      curl -sS --max-time 15 --data-binary @/root/build.tar.gz \\
           https://$ip:8443/publish
      PUB
      chmod +x /usr/local/bin/publish

      for _ in $(seq 1 20); do
        curl -sk -m 1 "https://$ip:8443/" 2>/dev/null \
          | grep -q vhost-gateway-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<Q
      The deploy step has not published a build since Tuesday. It runs
      /usr/local/bin/publish and it fails:

        curl: (60) SSL: no alternative certificate subject name matches
        target ipv4 address '$ip'

      Reaching the same gateway by name fails too, and differently:

        \$ curl https://artifacts.corp:8443/
        curl: (60) SSL certificate problem: unable to get local issuer certificate

      One listener, two error messages. They are two separate faults.

      Everything anyone has checked says the certificate is fine:

        - it expires in 2028, not last week
        - Corp Root CA 2026 is in this box's trust store
        - curl -k https://artifacts.corp:8443/ returns the gateway greeting
        - the internal-tools.corp site on the same listener verifies fine

      Somebody has already suggested adding the issuing CA to the trust store
      on the CI runners. Do not. Every other client on the network — browsers,
      Java, Go, the phones — has the same trust store this box does, and none of
      them will have that file.

      Three things to do.

      1. Make https://artifacts.corp:8443/ verify against the system trust
         store, from an unmodified client. The trust store may not gain a new
         anchor: the root is already there, and it is the only one that belongs
         there.

      2. Make /usr/local/bin/publish succeed with verification switched on. -k
         and --insecure are not fixes, they are the bug report.

      3. Write /root/answers/tls.md, exactly two lines:

           missing_link: <the certificate the gateway was not sending>
           no_sni_vhost: <the site that answers when no server name is sent>

      internal-tools.corp is another team's site on that same listener and it is
      the default vhost. It was working before you started and it has to be the
      default, and working, when you are finished.
      Q

      echo "scenario ready — curl -k works, and nothing else does"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      ip=$(cat /opt/vhosts/address 2>/dev/null || true)
      : "${ip:=127.0.0.1}"

      # ---- the chain, judged the way a stranger judges it ---------------
      #
      # Only the root is offered as an anchor. Nothing on this box's trust
      # store counts here, which is the point: this is the same view a laptop
      # or a Go binary elsewhere on the network gets. It can only succeed if
      # the gateway itself hands over the intermediate.
      chain=$(echo | openssl s_client -connect "$ip:8443" \
                -servername artifacts.corp -showcerts \
                -CAfile /opt/pki/root.crt -verify_return_error 2>&1 || true)

      if ! echo "$chain" | grep -q 'Verify return code: 0 (ok)'; then
        echo "not yet: artifacts.corp still does not verify with only the root as an"
        echo "         anchor, which is the view every other client on the network has."
        if echo "$chain" | grep -qi 'unable to get local issuer'; then
          echo "         The error is still 'unable to get local issuer certificate':"
          echo "         the gateway is sending the leaf and stopping there. Something"
          echo "         has to carry the signature from the leaf up to the root."
        fi
        exit 1
      fi

      # The subject lines of the chain s_client was actually handed. Counting
      # BEGIN CERTIFICATE would over-count: s_client prints the leaf a second
      # time under "Server certificate".
      offered=$(echo "$chain" | grep -E '^[[:space:]]*[0-9]+ s:')
      sent=$(printf '%s\n' "$offered" | grep -c 's:')

      if [ "$sent" -lt 2 ]; then
        echo "not yet: the gateway sent $sent certificate(s) for artifacts.corp."
        echo "         A client that has only the root has to be handed everything"
        echo "         between it and the leaf. That is one more certificate than the"
        echo "         gateway is sending."
        exit 1
      fi

      if ! printf '%s\n' "$offered" | grep -q 'Corp Issuing CA 2026'; then
        echo "not yet: the certificate the gateway sends alongside the leaf is not the"
        echo "         issuing CA. Check what signed artifacts.corp:"
        echo "           openssl x509 -in /opt/pki/artifacts.corp.crt -noout -issuer"
        exit 1
      fi

      # ---- and the way this box's own clients judge it ------------------
      greet=$(curl -sS -m 10 "https://artifacts.corp:8443/" 2>&1 || true)
      if ! echo "$greet" | grep -q 'vhost-gateway-2026'; then
        echo "not yet: curl https://artifacts.corp:8443/ — no -k — still does not"
        echo "         work against the system trust store. It said:"
        echo "         $greet"
        exit 1
      fi

      # ---- the neighbour's site is untouched ----------------------------
      other=$(echo | openssl s_client -connect "$ip:8443" \
                -servername internal-tools.corp \
                -CAfile /opt/pki/root.crt -verify_return_error 2>&1 || true)
      if ! echo "$other" | grep -q 'Verify return code: 0 (ok)'; then
        echo "not yet: internal-tools.corp on the same listener no longer verifies."
        echo "         It did before you started. Another team owns it."
        exit 1
      fi

      # ---- the default vhost is still the default -----------------------
      #
      # -noservername sends no SNI at all, which is what a client that dials an
      # IP address does. Making artifacts.corp the default would make the
      # broken publish script work without anyone learning why it was broken,
      # and would hand artifacts' certificate to every stray client that ever
      # dials this box by address.
      bare=$(echo | openssl s_client -connect "$ip:8443" -noservername 2>/dev/null \
             | openssl x509 -noout -subject 2>/dev/null || true)
      if ! echo "$bare" | grep -q 'internal-tools.corp'; then
        echo "not yet: with no server name sent, this listener answers with:"
        echo "           ${bare:-nothing at all}"
        echo "         internal-tools.corp is the default vhost and has to stay the"
        echo "         default. The publish script has to send the name instead."
        exit 1
      fi

      # ---- the deploy step ----------------------------------------------
      if grep -Eq -- '(-k([[:space:]]|$)|--insecure|CURL_CA_BUNDLE=|verify[[:space:]]*=[[:space:]]*False)' \
           /usr/local/bin/publish; then
        echo "not yet: /usr/local/bin/publish turns verification off. That publishes"
        echo "         the build to whoever answers on that address, which is the"
        echo "         thing certificates exist to prevent."
        exit 1
      fi

      before=$(wc -l < /var/log/vhosts.log 2>/dev/null || echo 0)
      out=$(/usr/local/bin/publish 2>&1 || true)

      if ! echo "$out" | grep -q 'published bytes=65536'; then
        echo "not yet: /usr/local/bin/publish does not complete. It said:"
        echo "         $out"
        exit 1
      fi

      new=$(tail -n "+$((before + 1))" /var/log/vhosts.log 2>/dev/null || true)
      if ! echo "$new" | grep -q 'sni=artifacts.corp'; then
        echo "not yet: publish reached the gateway, but the gateway did not see the"
        echo "         name artifacts.corp in the handshake. It logged:"
        echo "         ${new:-nothing}"
        echo "         A URL with an IP address in it sends no server name at all."
        exit 1
      fi

      # ---- the two answers ----------------------------------------------
      if [ ! -s /root/answers/tls.md ]; then
        echo "not yet: /root/answers/tls.md is missing or empty."
        echo "         Two faults were hiding behind one error message. Name them."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/tls.md)
      link=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*missing_link[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)
      vhost=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*no_sni_vhost[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)

      fail=0

      case "$link" in
        *issuing*|*intermediate*)
          ;;
        "")
          fail=1
          echo "not yet: no missing_link line in /root/answers/tls.md."
          ;;
        *root*)
          fail=1
          echo "not yet: you said missing_link=$link."
          echo "         The root was never missing — it is in the trust store, which is"
          echo "         where roots live. A server never needs to send it. What was"
          echo "         missing is the certificate between the leaf and the root."
          ;;
        *artifacts*|*leaf*)
          fail=1
          echo "not yet: you said missing_link=$link."
          echo "         The leaf was being sent all along; that is why -k worked and why"
          echo "         the expiry date was a red herring. Look at what signed it."
          ;;
        *)
          fail=1
          echo "not yet: you said missing_link=$link."
          echo "           openssl x509 -in /opt/pki/artifacts.corp.crt -noout -issuer"
          echo "         names the certificate the gateway should have been sending."
          ;;
      esac

      case "$vhost" in
        *internal-tools*)
          ;;
        "")
          fail=1
          echo "not yet: no no_sni_vhost line in /root/answers/tls.md."
          ;;
        *artifacts*)
          fail=1
          echo "not yet: you said no_sni_vhost=$vhost."
          echo "         artifacts.corp is what the client wanted and not what it got."
          echo "         Ask the listener directly:"
          echo "           openssl s_client -connect $ip:8443 -noservername"
          ;;
        *)
          fail=1
          echo "not yet: you said no_sni_vhost=$vhost."
          echo "           openssl s_client -connect $ip:8443 -noservername | \\"
          echo "             openssl x509 -noout -subject"
          echo "         names the site that answers when no server name is sent."
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — artifacts.corp verifies from a client that trusts only the root, the"
      echo "       publish step sends the name and succeeds with verification on, and"
      echo "       internal-tools.corp is still the default vhost and still verifies."
