---
kind: lesson
title: "the certificate is fine and the handshake still fails"
description: |
  ledger-sync cannot complete a TLS handshake against a service on the same box.
  `curl` to the same URL from your shell works. The certificate is valid, the
  chain is intact, the hostname matches — and the client rejects it anyway,
  because the client and the box do not agree on what day it is.
name: clock-skew
slug: clock-skew
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /etc/ledger /srv/ledger /root/answers /var/lib/devopslings
      rm -f /srv/ledger/last-sync

      grep -q 'ledger.internal' /etc/hosts || echo '127.0.0.1 ledger.internal' >> /etc/hosts

      # A private CA and a server certificate that is valid right now and for a
      # year. Nothing about the PKI is wrong in this lesson.
      # OpenSSL 3.5 rejects a CA certificate with no keyUsage extension, so the
      # CA is generated with explicit basicConstraints and keyUsage rather than
      # the bare -x509 defaults.
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/ledger/ca.key -out /etc/ledger/ca.crt \
        -subj '/CN=devopslings-local-ca' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1

      openssl req -newkey rsa:2048 -nodes \
        -keyout /etc/ledger/server.key -out /etc/ledger/server.csr \
        -subj '/CN=ledger.internal' >/dev/null 2>&1

      cat > /etc/ledger/san.cnf <<'CNF'
      subjectAltName = DNS:ledger.internal
      basicConstraints = CA:FALSE
      keyUsage = critical, digitalSignature, keyEncipherment
      extendedKeyUsage = serverAuth
      CNF

      openssl x509 -req -in /etc/ledger/server.csr \
        -CA /etc/ledger/ca.crt -CAkey /etc/ledger/ca.key -CAcreateserial \
        -days 365 -extfile /etc/ledger/san.cnf \
        -out /etc/ledger/server.crt >/dev/null 2>&1
      chmod 0644 /etc/ledger/*.crt /etc/ledger/*.key

      cat > /usr/local/bin/ledger-api <<'PY'
      #!/usr/bin/env python3
      import http.server, ssl

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.end_headers()
              self.wfile.write(b"ledger ok\n")
          def log_message(self, *a):
              pass

      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      ctx.load_cert_chain("/etc/ledger/server.crt", "/etc/ledger/server.key")
      srv = http.server.HTTPServer(("127.0.0.1", 8443), H)
      srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
      print("ledger-api: listening on 8443", flush=True)
      srv.serve_forever()
      PY
      chmod 0755 /usr/local/bin/ledger-api

      cat > /usr/local/bin/ledger-sync <<'PY'
      #!/usr/bin/env python3
      import ssl, sys, time, urllib.request

      # Full verification against the private CA. Never disable this to make the
      # error go away: it is the only thing standing between you and anyone who
      # can answer on that address.
      ctx = ssl.create_default_context(cafile="/etc/ledger/ca.crt")
      try:
          with urllib.request.urlopen("https://ledger.internal:8443/status",
                                      context=ctx, timeout=5) as r:
              body = r.read().decode().strip()
      except Exception as e:
          print(f"ledger-sync: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
          sys.exit(1)

      # Record what THIS process believes the time is, alongside the result.
      with open("/srv/ledger/last-sync", "w") as f:
          f.write(f"{int(time.time())} {body}\n")
      print(f"ledger-sync: {body}", flush=True)
      PY
      chmod 0755 /usr/local/bin/ledger-sync

      cat > /etc/systemd/system/ledger-api.service <<'UNIT'
      [Unit]
      Description=Ledger API (TLS)

      [Service]
      ExecStart=/usr/local/bin/ledger-api
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /etc/systemd/system/ledger-sync.service <<'UNIT'
      [Unit]
      Description=Ledger sync client
      After=ledger-api.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/ledger-sync
      UNIT

      # The skew, confined to this one unit. Somebody added it during a
      # date-handling test in June and left it behind — the box's own clock is
      # correct and always has been.
      lib=$(find /usr/lib -name 'libfaketime.so*' 2>/dev/null | head -1)
      printf '%s\n' "$lib" > /var/lib/devopslings/clock.lib
      install -d /etc/systemd/system/ledger-sync.service.d
      cat > /etc/systemd/system/ledger-sync.service.d/10-testing.conf <<CONF
      [Service]
      Environment=LD_PRELOAD=$lib
      Environment=FAKETIME=-730d
      CONF

      systemctl daemon-reload
      systemctl enable ledger-api.service >/dev/null 2>&1 || true
      systemctl restart ledger-api.service >/dev/null 2>&1 || true
      sleep 3
      systemctl start ledger-sync.service >/dev/null 2>&1 || true

      echo clockskew > /var/lib/devopslings/clock.cause

      cat > /root/questions.txt <<'Q'
      ledger-sync cannot complete a TLS handshake against ledger.internal:8443,
      which is running on this same box. curl to the same URL works.

        /root/answers/cause   what is actually wrong. One of:

          clockskew     the two ends disagree about the current time
          expiredcert   the server certificate is past its notAfter
          badchain      the CA that signed it is not trusted by the client
          hostname      the name in the certificate does not match

      Then make ledger-sync complete successfully and write /srv/ledger/last-sync.

      Do not weaken the client: it must keep verifying the certificate against
      /etc/ledger/ca.crt. Do not reissue the certificate.
      Q

      echo "scenario ready — ledger-sync.service is failing its TLS handshake"
      journalctl -u ledger-sync.service --no-pager -o cat -n 3 2>&1 | tail -3 || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      want=$(cat /var/lib/devopslings/clock.cause)

      if [ ! -s /root/answers/cause ]; then
        echo "not yet: /root/answers/cause is missing or empty"
        echo "         one of: clockskew, expiredcert, badchain, hostname"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/cause | tr 'A-Z' 'a-z')
      if [ "$got" != "$want" ]; then
        case "$got" in
          expiredcert)
            echo "not yet: check the certificate's dates against the box's clock:"
            echo "           openssl x509 -in /etc/ledger/server.crt -noout -dates"
            echo "         it became valid today and expires in a year. It is not expired."
            ;;
          badchain)
            echo "not yet: the client is given /etc/ledger/ca.crt explicitly, and that CA"
            echo "         did sign this certificate. Verify it yourself:"
            echo "           openssl verify -CAfile /etc/ledger/ca.crt /etc/ledger/server.crt"
            ;;
          hostname)
            echo "not yet: the certificate carries subjectAltName DNS:ledger.internal and"
            echo "         that is the name being requested. A hostname mismatch also says"
            echo "         so explicitly — read the client's error again."
            ;;
          *)
            echo "not yet: '$got' is not one of clockskew, expiredcert, badchain, hostname"
            ;;
        esac
        exit 1
      fi

      # The certificate must be the original one.
      if ! openssl verify -CAfile /etc/ledger/ca.crt /etc/ledger/server.crt >/dev/null 2>&1; then
        echo "not yet: /etc/ledger/server.crt no longer verifies against the CA — reset the lesson"
        exit 1
      fi

      # The client must still verify. If create_default_context or the cafile is
      # gone, the handshake succeeding proves nothing.
      if ! grep -q 'create_default_context' /usr/local/bin/ledger-sync 2>/dev/null \
         || ! grep -q '/etc/ledger/ca.crt' /usr/local/bin/ledger-sync 2>/dev/null; then
        echo "not yet: ledger-sync no longer verifies the certificate against the CA."
        echo "         Turning verification off makes the error disappear and makes the"
        echo "         connection meaningless. Reset the lesson and fix the clock."
        exit 1
      fi
      if grep -qi 'CERT_NONE\|check_hostname *= *False\|verify *= *False' /usr/local/bin/ledger-sync 2>/dev/null; then
        echo "not yet: ledger-sync has had certificate verification disabled."
        exit 1
      fi

      rm -f /srv/ledger/last-sync
      systemctl reset-failed ledger-sync.service >/dev/null 2>&1 || true
      if ! systemctl start ledger-sync.service >/dev/null 2>&1; then
        echo "not yet: ledger-sync.service still fails"
        journalctl -u ledger-sync.service --no-pager -o cat -n 5 2>&1 | sed 's/^/         /'
        exit 1
      fi

      if [ ! -s /srv/ledger/last-sync ]; then
        echo "not yet: ledger-sync reported success but wrote no /srv/ledger/last-sync"
        exit 1
      fi

      # The decisive check: what did the SERVICE think the time was? A handshake
      # that succeeds because the certificate was reissued into the past would
      # pass everything above and leave the skew exactly where it was.
      observed=$(awk '{print $1}' /srv/ledger/last-sync)
      real=$(date +%s)
      drift=$(( observed > real ? observed - real : real - observed ))
      if [ "$drift" -gt 120 ]; then
        human=$(date -u -d "@$observed" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
        echo "not yet: the handshake worked, but ledger-sync still thinks it is $human"
        echo "         — ${drift}s away from this box's clock. The skew is still there;"
        echo "         something else made the error go away."
        exit 1
      fi

      echo "PASS — cause identified as $want; ledger-sync verifies the certificate and"
      echo "       its clock is within ${drift}s of the box."
---
